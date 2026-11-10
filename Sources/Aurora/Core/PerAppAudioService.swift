//  PerAppAudioService.swift
//  Aurora — 按应用调节输出音量
//
//  原理（macOS 14.2+ 的 CoreAudio 进程 tap）：
//  1. 用 CATapDescription 给某个进程建 tap，muteBehavior = .muted，让它的声音不再直接进硬件；
//  2. 把 tap 包进一个私有聚合设备，用 IOProc 读出它的 PCM；
//  3. 用 AUHAL 输出单元把同一份 PCM 乘上增益后送回当前输出设备。
//  这样每个 App 都有独立音量，且不改变系统默认输出设备。
//
//  安全策略：
//  · 只有音量 ≠ 100% 的应用才建链路，100% 时完全不介入（原生通路，零延迟）；
//  · 进程退出/音量回到 100%/切换输出设备时立刻拆除链路，声音自动回到原状；
//  · 应用退出时系统会销毁 tap，不会留下「静音但无法恢复」的状态。

import AppKit
import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import os

// MARK: - 环形缓冲（交错立体声 float32）

final class TapRing {
    let capacity: Int
    private var buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var readIndex = 0
    private var available = 0
    private var lock = os_unfair_lock_s()

    init(capacity: Int = 16384) {
        self.capacity = capacity
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        buffer.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        buffer.deinitialize(count: capacity * 2)
        buffer.deallocate()
    }

    func write(frames: Int, source: UnsafePointer<Float>) {
        guard frames > 0 else { return }
        // 音频线程不能被阻塞：拿不到锁就丢掉这一块
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        let count = min(frames, capacity)
        if count == capacity {
            readIndex = 0
            writeIndex = 0
            available = 0
        }
        // 满了就丢最旧的，保持低延迟
        let overflow = available + count - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            available -= overflow
        }

        var remaining = count
        var srcFrame = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            buffer.advanced(by: writeIndex * 2).update(from: source.advanced(by: srcFrame * 2), count: chunk * 2)
            writeIndex = (writeIndex + chunk) % capacity
            srcFrame += chunk
            remaining -= chunk
        }
        available += count
    }

    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard os_unfair_lock_trylock(&lock) else { return 0 }
        defer { os_unfair_lock_unlock(&lock) }

        let count = min(frames, available)
        var dstFrame = 0
        while dstFrame < count {
            let chunk = min(count - dstFrame, capacity - readIndex)
            let base = buffer.advanced(by: readIndex * 2)
            (dst + dstFrame * 2).update(from: base, count: chunk * 2)
            readIndex = (readIndex + chunk) % capacity
            dstFrame += chunk
        }
        available -= count
        return count
    }

    var buffered: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return available
    }
}

@_silgen_name("proc_name")
private func aurora_audio_proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32

// MARK: - 单个应用的链路

final class AppAudioChain {
    let bundleID: String
    let pid: pid_t
    let processObject: AudioObjectID

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioDeviceID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputUnit: AudioUnit?
    private let ring = TapRing()

    /// 目标增益与平滑后的增益：控制线程写 target，音频线程读
    private let targetGain: UnsafeMutablePointer<Float>
    private var smoothedGain: Float = 1
    private var lastHostTime: UInt64 = 0
    private var running = false
    var deviceID: AudioDeviceID = 0

    /// 诊断用计数（音频线程累加，仅用于自检输出）
    private(set) var capturedFrames = 0
    private(set) var renderedFrames = 0
    /// 连续空读次数：长时间拿不到数据说明链路失效，必须拆掉，否则用户会「被静音」
    private(set) var peak: Float = 0
    private var emptyCallbacks = 0
    var stalled = false
    /// 该应用此刻是否在输出声音；暂停时不算「链路失效」
    var expectingAudio = false


    /// mute == false 时只「旁听」不打断原生通路，用来测量某个进程此刻到底有没有声音
    private let muteSource: Bool

    init(bundleID: String, pid: pid_t, processObject: AudioObjectID, gain: Float, mute: Bool = true) {
        self.bundleID = bundleID
        self.pid = pid
        self.processObject = processObject
        self.muteSource = mute
        targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        targetGain.initialize(to: gain)
    }

    deinit {
        targetGain.deallocate()
    }

    var isRunning: Bool { running }

    func setGain(_ value: Float) {
        targetGain.pointee = value
    }

    private static var tracing: Bool { ProcessInfo.processInfo.environment["AURORA_AUDIO_TRACE"] == "1" }

    private func trace(_ label: String) {
        guard Self.tracing else { return }
        print("  [trace] \(label) deviceVolume=\(String(format: "%.3f", Self.deviceVolume())) unitVolume=\(String(format: "%.3f", self.outputUnitVolume()))")
    }

    // MARK: 设备静音/音量的快照与恢复

    /// 建立 tap + AUHAL 之后，系统偶尔会把输出设备切成「静音」（音量随之淡出到 0），
    /// 表现为「调过某个 App 的音量后，它自己或整个系统的声音变成 0%」。
    /// 这里在接管前记一份状态，接管后与拆除后各校正一次，只恢复被改坏的部分。
    private var savedMute: Bool = false
    private var savedVolume: Float = -1

    private static func deviceMuteIsOn() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(defaultOutputDevice(), &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(defaultOutputDevice(), &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setDeviceMute(_ muted: Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(defaultOutputDevice(), &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(defaultOutputDevice(), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func setDeviceVolume(_ value: Float) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(defaultOutputDevice(), &address) else { return }
        var v = value
        AudioObjectSetPropertyData(defaultOutputDevice(), &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
    }

    /// 只有「我们接管前没静音、接管后变静音」才恢复，避免覆盖用户主动静音
    func restoreDeviceState() {
        // 自检用：AURORA_NO_RESTORE=1 时关掉校正，用来确认「不修就会坏」
        guard ProcessInfo.processInfo.environment["AURORA_NO_RESTORE"] != "1" else { return }
        guard savedMute == false else { return }
        if Self.deviceMuteIsOn() == true {
            Self.setDeviceMute(false)
            Debug.log("audio: 输出设备被系统置为静音，已恢复")
        }
        if savedVolume > 0.02, Self.deviceVolume() < 0.01 {
            Self.setDeviceVolume(savedVolume)
            Debug.log("audio: 输出音量被清零，已恢复到 \(savedVolume)")
        }
    }

    static func deviceVolume() -> Float {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float = -1
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(defaultOutputDevice(), &address, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    private func outputUnitVolume() -> Float {
        guard let unit = outputUnit else { return -1 }
        var value: Float = -1
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioUnitGetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0, &value) == noErr else { return -1 }
        _ = size
        return value
    }

    func start() -> Bool {
        guard !running else { return true }
        trace("start 前")
        savedMute = Self.deviceMuteIsOn() ?? false
        savedVolume = Self.deviceVolume()

        let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
        desc.name = "Aurora · \(bundleID)"
        desc.uuid = UUID()
        desc.muteBehavior = muteSource ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted

        var tap = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else {
            Debug.log("audio: tap 创建失败 \(bundleID)")
            return false
        }
        tapID = tap
        trace("create tap 后")

        let aggregateUID = "aurora.tap.\(UUID().uuidString)"
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Aurora Reader",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [["uid": desc.uuid.uuidString, "drift": true]]
        ]
        var aggregate = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            tapID = 0
            Debug.log("audio: 聚合设备创建失败 \(bundleID)")
            return false
        }
        aggregateID = aggregate
        trace("create aggregate 后")

        // tap 的格式
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(aggregate, &formatAddress, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame >= 2 else {
            teardown()
            return false
        }
        let sampleRate = asbd.mSampleRate

        // 读取 tap 的 IOProc
        let ring = self.ring
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, inData, _, _, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = inputs.first, let data = first.mData else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * 2)
            self.capturedFrames += frames
            ring.write(frames: frames, source: data.assumingMemoryBound(to: Float.self))
        }
        guard ioStatus == noErr, let procID else {
            teardown()
            return false
        }
        ioProcID = procID
        guard AudioDeviceStart(aggregate, procID) == noErr else {
            teardown()
            return false
        }
        trace("aggregate start 后")

        // 输出单元
        deviceID = Self.defaultOutputDevice()
        guard let unit = Self.makeOutputUnit(device: deviceID, sampleRate: sampleRate, ring: ring, host: self) else {
            teardown()
            return false
        }
        outputUnit = unit
        trace("AUHAL 创建后（未初始化）")
        guard AudioUnitInitialize(unit) == noErr else {
            teardown()
            return false
        }
        trace("AUHAL initialize 后")
        guard AudioOutputUnitStart(unit) == noErr else {
            teardown()
            return false
        }
        trace("AUHAL start 后")
        // 接管刚完成的这一小段时间里最容易把设备切静音，稍后再校正一次
        restoreDeviceState()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.restoreDeviceState()
        }

        running = true
        Debug.log("audio: 已接管 \(bundleID) pid=\(pid) rate=\(Int(sampleRate))")
        return true
    }

    /// 音频线程调用：取一帧数据并按平滑增益输出
    fileprivate func render(into dst: UnsafeMutablePointer<Float>, frames: Int) {
        dst.update(repeating: 0, count: frames * 2)
        let obtained = ring.read(into: dst, frames: frames)
        if obtained > 0 {
            renderedFrames += obtained
            emptyCallbacks = 0
        } else if expectingAudio {
            emptyCallbacks += 1
            // 约 3 秒（1024 帧 / 48kHz ≈ 47 次每秒）
            if emptyCallbacks > 160 { stalled = true }
        }
        let target = targetGain.pointee
        let step = (target - smoothedGain) / Float(max(frames, 1))
        var gain = smoothedGain
        for frame in 0..<obtained {
            gain += step
            // 超过 100% 时做硬限幅，避免爆音
            dst[frame * 2] = min(max(dst[frame * 2] * gain, -1), 1)
            dst[frame * 2 + 1] = min(max(dst[frame * 2 + 1] * gain, -1), 1)
            let amplitude = abs(dst[frame * 2])
            if amplitude > peak { peak = amplitude }
        }
        smoothedGain = gain
        if obtained < frames {
            // 欠载时把差的部分留成静音，并让平滑值向目标收敛
            smoothedGain = target
        }
    }

    func teardown() {
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            trace("teardown: unit stop")
            AudioUnitUninitialize(unit)
            trace("teardown: unit uninit")
            AudioComponentInstanceDispose(unit)
            trace("teardown: unit dispose")
        }
        outputUnit = nil
        if let procID = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            trace("teardown: aggregate stop")
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            trace("teardown: ioproc destroyed")
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
            trace("teardown: aggregate destroyed")
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            trace("teardown: tap destroyed")
        }
        running = false
    }

    // MARK: - HAL

    static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func makeOutputUnit(device: AudioDeviceID, sampleRate: Double, ring: TapRing, host: AppAudioChain) -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }

        var enable: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, 4)
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, 4)

        var deviceID = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, 4)

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &client,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        let callback: AURenderCallback = { refCon, _, _, _, frameCount, ioData -> OSStatus in
            guard let ioData else { return noErr }
            let chain = Unmanaged<AppAudioChain>.fromOpaque(refCon).takeUnretainedValue()
            let outputs = UnsafeMutableAudioBufferListPointer(ioData)
            guard let first = outputs.first, let data = first.mData else { return noErr }
            chain.render(into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: callback,
            inputProcRefCon: Unmanaged.passUnretained(host).toOpaque()
        )
        guard AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }
}

// MARK: - 对外服务

struct AppAudioItem: Identifiable, Equatable {
    let id: String        // bundle id
    var name: String
    var pid: pid_t
    var volume: Double    // 0 ... 1.5
    var isMuted: Bool
    var isControlled: Bool
}

@MainActor
final class PerAppAudioService: ObservableObject {
    @Published private(set) var items: [AppAudioItem] = []
    @Published private(set) var isSupported = true
    @Published private(set) var lastError: String?
    @Published private(set) var controlledCount = 0

    private var moduleEnabled = true
    private var volumes: [String: Double]
    private var chains: [String: AppAudioChain] = [:]
    private var failures: [String: Date] = [:]
    private var timer: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastDevice = AudioDeviceID(0)
    private let queue = DispatchQueue(label: "aurora.audio.engine", qos: .userInitiated)

    private static let volumesKey = "audio.appVolumes"

    init() {
        volumes = (UserDefaults.standard.dictionary(forKey: Self.volumesKey) as? [String: Double]) ?? [:]
        if #available(macOS 14.2, *) {
            isSupported = true
        } else {
            isSupported = false
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        installDeviceListener()
    }

    deinit {
        timer?.invalidate()
        if let deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, deviceListener
            )
        }
    }

    // MARK: - 查询

    func volume(for bundleID: String) -> Double {
        volumes[bundleID] ?? 1.0
    }

    func isControlled(_ bundleID: String) -> Bool {
        chains[bundleID] != nil
    }

    func setVolume(_ value: Double, for bundleID: String) {
        let clamped = min(max(value, 0), 1.5)
        volumes[bundleID] = clamped
        persist()
        if let chain = chains[bundleID] {
            chain.setGain(Float(clamped))
        }
        syncChains()
        refresh()
    }

    func toggleMute(_ bundleID: String) {
        let current = volume(for: bundleID)
        if current > 0.001 {
            volumes[bundleID] = 0
        } else {
            volumes[bundleID] = 1.0
        }
        persist()
        chains[bundleID]?.setGain(Float(volume(for: bundleID)))
        syncChains()
        refresh()
    }

    func resetAll() {
        volumes = volumes.mapValues { _ in 1.0 }
        persist()
        failures.removeAll()
        lastError = nil
        shutdown()
        refresh()
    }

    /// 退出前调用，确保所有 tap 拆除（否则退出瞬间声音会被静音掉一帧）
    func shutdown() {
        for chain in chains.values { chain.teardown() }
        chains.removeAll()
        controlledCount = 0
    }

    // MARK: - 刷新

    private func persist() {
        UserDefaults.standard.set(volumes, forKey: Self.volumesKey)
    }

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        if enabled { refresh() } else { shutdown() }
    }

    func refresh() {
        guard moduleEnabled else { return }
        let processes = Self.audioProcesses()
        var visible: [AppAudioItem] = []
        var seen = Set<String>()

        for process in processes {
            guard process.pid > 0, process.pid != getpid() else { continue }
            let bundleID = process.bundleID.isEmpty ? "pid:\(process.pid)" : process.bundleID
            guard !seen.contains(bundleID) else { continue }
            guard !Self.systemBlocklist.contains(bundleID) else { continue }
            // 只列真正在输出声音的应用；已经调过音量的即使暂停也保留在列表里
            guard process.isPlaying || chains[bundleID] != nil || abs(volume(for: bundleID) - 1.0) > 0.001 else { continue }

            if NSRunningApplication(processIdentifier: process.pid)?.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            guard let name = Self.displayName(pid: process.pid, bundleID: bundleID) else { continue }
            let volume = volume(for: bundleID)
            seen.insert(bundleID)
            visible.append(AppAudioItem(
                id: bundleID,
                name: name,
                pid: process.pid,
                volume: volume,
                isMuted: volume <= 0.001,
                isControlled: chains[bundleID]?.isRunning == true
            ))
        }

        // 正在被调音的应用即使暂时没发声也保留在列表里，避免滑块消失
        for (bundleID, chain) in chains where !seen.contains(bundleID) {
            visible.append(AppAudioItem(
                id: bundleID,
                name: Self.displayName(pid: chain.pid, bundleID: bundleID) ?? bundleID,
                pid: chain.pid,
                volume: volume(for: bundleID),
                isMuted: volume(for: bundleID) <= 0.001,
                isControlled: chain.isRunning
            ))
        }

        items = visible.sorted { lhs, rhs in
            if lhs.isControlled != rhs.isControlled { return lhs.isControlled }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        controlledCount = chains.values.filter(\.isRunning).count
        syncChains(processes: processes)
    }

    /// 让链路状态与「音量是否为默认」保持一致
    private func syncChains(processes: [(object: AudioObjectID, pid: pid_t, bundleID: String, isPlaying: Bool)]? = nil) {
        guard isSupported, moduleEnabled else { return }
        let list = processes ?? Self.audioProcesses()
        var wanted: [(bundleID: String, pid: pid_t, object: AudioObjectID, gain: Float)] = []

        for process in list {
            guard process.pid > 0, process.pid != getpid() else { continue }
            let bundleID = process.bundleID.isEmpty ? "pid:\(process.pid)" : process.bundleID
            guard !Self.systemBlocklist.contains(bundleID) else { continue }
            let gain = volume(for: bundleID)
            guard abs(gain - 1.0) > 0.001 else { continue }
            guard process.isPlaying || chains[bundleID] != nil else { continue }
            if NSRunningApplication(processIdentifier: process.pid)?.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            guard Self.displayName(pid: process.pid, bundleID: bundleID) != nil else { continue }
            if wanted.contains(where: { $0.bundleID == bundleID }) { continue }
            wanted.append((bundleID, process.pid, process.object, Float(gain)))
        }

        let wantedIDs = Set(wanted.map(\.bundleID))
        // 进程重启/音频对象变化/链路失效后 tap 会失效，直接重建或拆掉
        for (key, chain) in chains {
            let current = wanted.first { $0.bundleID == key }
            if current == nil || !chain.isRunning || current?.object != chain.processObject || chain.stalled {
                if chain.stalled {
                    Debug.log("audio: \(key) 链路无数据，已拆除以免静音")
                    failures[key] = Date()
                }
                chain.teardown()
                chains.removeValue(forKey: key)
            }
        }

        for target in wanted where chains[target.bundleID] == nil {
            if let failedAt = failures[target.bundleID], Date().timeIntervalSince(failedAt) < 30 { continue }
            let chain = AppAudioChain(
                bundleID: target.bundleID,
                pid: target.pid,
                processObject: target.object,
                gain: target.gain
            )
            if chain.start() {
                chains[target.bundleID] = chain
                failures.removeValue(forKey: target.bundleID)
            } else {
                failures[target.bundleID] = Date()
                lastError = TF("无法接管 %@ 的音频", target.bundleID)
            }
        }

        for (key, chain) in chains {
            chain.setGain(Float(volume(for: key)))
            chain.expectingAudio = list.contains { process in
                let id = process.bundleID.isEmpty ? "pid:\(process.pid)" : process.bundleID
                return id == key && process.isPlaying
            }
        }
        controlledCount = chains.values.filter(\.isRunning).count
    }

    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let current = AppAudioChain.defaultOutputDevice()
                guard current != self.lastDevice else { return }
                self.lastDevice = current
                // 换了输出设备就重建链路，否则声音会送到旧设备
                for chain in self.chains.values { chain.teardown() }
                self.chains.removeAll()
                self.syncChains()
            }
        }
        lastDevice = AppAudioChain.defaultOutputDevice()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        deviceListener = block
    }

    // MARK: - 进程

    private struct AudioProcess {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
    }

    /// 自检用：按 pid 找音频进程对象
    static func debugProcessObject(pid: pid_t) -> AudioObjectID {
        audioProcesses().first { $0.pid == pid }?.object ?? 0
    }

    /// 显示名：优先 App 名称，命令行播放器退回到进程名
    private static func displayName(pid: pid_t, bundleID: String) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if aurora_audio_proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        guard !bundleID.isEmpty else { return nil }
        return (bundleID as NSString).lastPathComponent
    }

    /// 系统自带的后台音频代理，列出来只会干扰
    private static let systemBlocklist: Set<String> = [
        "com.apple.controlcenter", "com.apple.audiomxd", "com.apple.mediaremoted",
        "com.apple.CoreSpeech", "com.apple.speech.speechsynthesisd", "com.apple.Siri",
        "com.apple.universalaccessd", "com.apple.avconferenced", "com.apple.TelephonyUtilities",
        "com.apple.cloudpaird", "com.apple.cmio.ContinuityCaptureAgent", "com.apple.accessibility.heard"
    ]

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7069726F), // 'piro' IsRunningOutput
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func audioProcesses() -> [(object: AudioObjectID, pid: pid_t, bundleID: String, isPlaying: Bool)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &list
        ) == noErr else { return [] }

        return list.compactMap { object in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioProcessPropertyPID),
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return nil }

            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioProcessPropertyBundleID),
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, $0)
            }
            let bundleID = status == noErr ? (bundle as String) : ""
            return (object, pid, bundleID, isRunningOutput(object))
        }
    }
}
