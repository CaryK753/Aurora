//  AudioService.swift
//  Aurora — 声音设备管理（CoreAudio HAL，参考 switchaudio-osx）

import AppKit
import Combine
import CoreAudio

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    var name: String
    var isOutput: Bool
    var isDefault: Bool
    var volume: Double
    var isMuted: Bool
    var transport: String
    var hasVolume: Bool
}

@MainActor
final class AudioService: ObservableObject {
    @Published private(set) var outputs: [AudioDeviceInfo] = []
    @Published private(set) var inputs: [AudioDeviceInfo] = []
    @Published private(set) var defaultOutputName: String = ""
    @Published private(set) var defaultInputName: String = ""
    /// 切换默认设备失败时的说明（设备离线 / 系统拒绝 / 被系统改回）
    @Published private(set) var switchError: String?

    private var mutedVolumes: [AudioDeviceID: Double] = [:]
    private var verifyTask: Task<Void, Never>?

    private var listeners: [AudioObservation] = []
    private var deviceListeners: [AudioObservation] = []
    private var observedDevices: Set<AudioDeviceID> = []

    init() {
        refresh()
        installListeners()
        // 后台回到前台时补一次同步：监听偶尔漏事件（休眠唤醒 / 其它 App 改路由）也能对上
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - 读取

    func refresh() {
        let defaultOutput = Self.defaultDevice(output: true)
        let defaultInput = Self.defaultDevice(output: false)

        var outList: [AudioDeviceInfo] = []
        var inList: [AudioDeviceInfo] = []

        for device in Self.allDevices() {
            let name = Self.name(of: device)
            let transport = Self.transportName(of: device)

            if Self.hasStreams(device, output: true) {
                let volume = Self.volume(of: device) ?? 0
                outList.append(AudioDeviceInfo(
                    id: device,
                    name: name,
                    isOutput: true,
                    isDefault: device == defaultOutput,
                    volume: volume,
                    isMuted: Self.isMuted(device) ?? (mutedVolumes[device] != nil),
                    transport: transport,
                    hasVolume: Self.volume(of: device) != nil
                ))
            }
            if Self.hasStreams(device, output: false) {
                inList.append(AudioDeviceInfo(
                    id: device,
                    name: name,
                    isOutput: false,
                    isDefault: device == defaultInput,
                    volume: Self.volume(of: device, output: false) ?? 0,
                    isMuted: Self.isMuted(device, output: false) ?? (mutedVolumes[device] != nil),
                    transport: transport,
                    hasVolume: Self.volume(of: device, output: false) != nil
                ))
            }
        }

        observeDevices(Set(outList.map(\.id) + inList.map(\.id)))
        outputs = outList.sorted { $0.isDefault && !$1.isDefault }
        inputs = inList.sorted { $0.isDefault && !$1.isDefault }
        defaultOutputName = outList.first(where: \.isDefault)?.name ?? "—"
        defaultInputName = inList.first(where: \.isDefault)?.name ?? "—"
    }

    // MARK: - 操作

    @discardableResult
    func setDefault(_ device: AudioDeviceInfo) -> Bool {
        guard Self.isAlive(device.id) else {
            switchError = TF("%@ 当前不在线，无法切换", device.name)
            refresh()
            return false
        }
        let status = Self.requestDefault(device.id, output: device.isOutput)
        guard status == noErr else {
            switchError = TF("系统拒绝了切换到 %@（错误 %d）", device.name, Int(status))
            refresh()
            return false
        }
        switchError = nil
        // CoreAudio 是异步落的：先本地刷新给即时反馈，再异步核对真实结果
        refresh()
        verifyDefault(device)
        return true
    }

    /// 切换后核对：系统偶尔会把默认设备改回去（设备休眠 / 路由被抢），
    /// 之前这里同步读回会导致「明明切成功了却提示失败」，所以改成异步确认。
    private func verifyDefault(_ device: AudioDeviceInfo) {
        verifyTask?.cancel()
        verifyTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, !Task.isCancelled else { return }
                if Self.defaultDevice(output: device.isOutput) == device.id {
                    self.refresh()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.refresh()
            let landed = Self.name(of: Self.defaultDevice(output: device.isOutput))
            self.switchError = TF("%@ 没有成为默认设备，系统仍在用 %@", device.name, landed)
        }
    }

    func clearSwitchError() { switchError = nil }

    func setVolume(_ value: Double, for device: AudioDeviceInfo) {
        Self.setVolume(device.id, value, output: device.isOutput)
        refresh()
    }

    func toggleMute(_ device: AudioDeviceInfo) {
        if Self.canSetMute(device.id, output: device.isOutput) {
            Self.setMuted(device.id, !device.isMuted, output: device.isOutput)
        } else if let previous = mutedVolumes.removeValue(forKey: device.id) {
            Self.setVolume(device.id, previous, output: device.isOutput)
        } else if device.hasVolume {
            mutedVolumes[device.id] = device.volume
            Self.setVolume(device.id, 0, output: device.isOutput)
        }
        refresh()
    }

    // MARK: - 通知

    private func installListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            if let observer = AudioObservation(object: AudioObjectID(kAudioObjectSystemObject),
                                               selector: selector, onChange: { [weak self] in
                Task { @MainActor in self?.refresh() }
            }) { listeners.append(observer) }
        }
    }

    private func observeDevices(_ devices: Set<AudioDeviceID>) {
        guard devices != observedDevices else { return }
        observedDevices = devices
        deviceListeners.removeAll()
        mutedVolumes = mutedVolumes.filter { devices.contains($0.key) }
        for device in devices {
            for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
                for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                    for element: AudioObjectPropertyElement in [0, 1, 2] {
                        if let observer = AudioObservation(object: device, selector: selector,
                                                           scope: scope, element: element,
                                                           onChange: { [weak self] in
                            Task { @MainActor in self?.refresh() }
                        }) { deviceListeners.append(observer) }
                    }
                }
            }
        }
    }

    // MARK: - HAL 辅助

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    static func defaultDevice(output: Bool) -> AudioDeviceID {
        var address = address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// 请求系统把某设备设为默认输入/输出
    static func requestDefault(_ device: AudioDeviceID, output: Bool) -> OSStatus {
        var address = address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
    }

    /// 设备是否还在线：离线设备设成默认会「静默失败」，先查一次避免误报成功
    static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        guard AudioObjectHasProperty(device, &address) else { return true }
        var value: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return true }
        return value != 0
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String) : T("未命名设备")
    }

    static func hasStreams(_ device: AudioDeviceID, output: Bool) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func transportName(of device: AudioDeviceID) -> String {
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return "" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return T("内建")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return T("蓝牙")
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return T("虚拟")
        case kAudioDeviceTransportTypeAggregate: return T("聚合")
        default: return T("其他")
        }
    }

    static func volume(of device: AudioDeviceID, output: Bool = true) -> Double? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return Double(value)
            }
        }
        return nil
    }

    static func setVolume(_ device: AudioDeviceID, _ value: Double, output: Bool = true) {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var scalar = Float32(min(max(value, 0), 1))
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        }
    }

    static func canSetMute(_ device: AudioDeviceID, output: Bool = true) -> Bool {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ device: AudioDeviceID, output: Bool = true) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool, output: Bool = true) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else {
            // 回退到软件静音：把音量设为 0
            if muted { setVolume(device, 0, output: output) }
            return
        }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
