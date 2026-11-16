//  WallpaperPlayback.swift
//  Aurora — 动态壁纸的播放策略：什么时候该动、什么时候该停
//
//  动态壁纸是常驻的：一块 4K 视频在锁屏、休眠、低电量、全屏看片时继续解码，
//  是这类工具最容易被骂的地方（发热、掉电、风扇响）。这里把「该不该播」拆成
//  一份纯逻辑（WallpaperPlaybackPolicy）+ 一份事件监听（WallpaperPlaybackMonitor），
//  渲染层只负责执行结论。参考 Phosphene 的 PlaybackPolicy：所有输入都是策略的
//  输入，任何一条要求暂停，就没有别的路径能把它播回去。

import AppKit
import Combine
import Foundation
import IOKit.ps

// MARK: - 暂停原因

enum WallpaperPauseReason: String, Equatable, Hashable {
    case manual
    case systemSleep
    case locked
    case screenSaver
    case displaySleep
    case thermal
    case lowPower
    case battery
    case fullscreen

    var title: String {
        switch self {
        case .manual: return T("已手动暂停")
        case .systemSleep: return T("系统睡眠中")
        case .locked: return T("锁屏中")
        case .screenSaver: return T("屏幕保护中")
        case .displaySleep: return T("显示器已休眠")
        case .thermal: return T("设备温度偏高")
        case .lowPower: return T("低电量模式")
        case .battery: return T("电量偏低")
        case .fullscreen: return T("全屏应用覆盖")
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "pause.fill"
        case .systemSleep: return "moon.zzz.fill"
        case .locked: return "lock.fill"
        case .screenSaver: return "sparkles.rectangle.stack.fill"
        case .displaySleep: return "display.slash"
        case .thermal: return "thermometer.high"
        case .lowPower: return "battery.25"
        case .battery: return "battery.0"
        case .fullscreen: return "rectangle.inset.filled"
        }
    }

    /// 给「为什么会停」的一句话解释，放在设置卡片里
    var detail: String {
        switch self {
        case .manual: return T("你在面板里手动停住了画面")
        case .systemSleep: return T("整机睡眠时不需要解码")
        case .locked: return T("锁屏时桌面被盖住，继续解码只是耗电")
        case .screenSaver: return T("屏保运行时桌面不可见")
        case .displaySleep: return T("显示器熄灭后停止解码")
        case .thermal: return T("芯片降频时优先保住性能")
        case .lowPower: return T("低电量模式下让出解码与合成开销")
        case .battery: return T("电量低于阈值时优先省电")
        case .fullscreen: return T("那块屏被全屏应用占满，桌面看不见")
        }
    }
}

// MARK: - 输入

/// 所有会让画面停下来的外部条件。纯值类型，方便单测直接构造。
struct WallpaperPlaybackInputs: Equatable {
    var isLocked = false
    var screenSaver = false
    var displayAsleep = false
    var systemSleeping = false
    var lowPowerMode = false
    var onBattery = false
    var batteryPercent = 100
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// 被全屏窗口完全覆盖的显示器（displayKey）
    var fullscreenDisplays: Set<String> = []
}

// MARK: - 用户开关

struct WallpaperPlaybackOptions: Codable, Equatable {
    var pauseOnLock = true
    var pauseOnFullscreen = true
    var pauseInLowPower = true
    var pauseOnThermal = true
    /// 电量低于该百分比时暂停；0 = 不按电量暂停
    var batteryFloor = 20

    static let storageKey = "wallpaper.playback.options"

    init() {}

    /// 逐项 decodeIfPresent：以后加字段时，老版本存下的配置不会整份作废
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WallpaperPlaybackOptions()
        pauseOnLock = try container.decodeIfPresent(Bool.self, forKey: .pauseOnLock) ?? fallback.pauseOnLock
        pauseOnFullscreen = try container.decodeIfPresent(Bool.self, forKey: .pauseOnFullscreen) ?? fallback.pauseOnFullscreen
        pauseInLowPower = try container.decodeIfPresent(Bool.self, forKey: .pauseInLowPower) ?? fallback.pauseInLowPower
        pauseOnThermal = try container.decodeIfPresent(Bool.self, forKey: .pauseOnThermal) ?? fallback.pauseOnThermal
        batteryFloor = try container.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? fallback.batteryFloor
    }

    static func load() -> WallpaperPlaybackOptions {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let options = try? JSONDecoder().decode(WallpaperPlaybackOptions.self, from: data) else {
            return WallpaperPlaybackOptions()
        }
        return options
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - 策略

enum WallpaperPlaybackPolicy {
    /// 与显示器无关的那部分结论（只要有就给所有屏生效）
    static func globalReason(
        inputs: WallpaperPlaybackInputs,
        options: WallpaperPlaybackOptions,
        manualPause: Bool
    ) -> WallpaperPauseReason? {
        if manualPause { return .manual }
        if inputs.systemSleeping { return .systemSleep }
        if inputs.isLocked { return .locked }
        if inputs.screenSaver { return .screenSaver }
        if inputs.displayAsleep { return .displaySleep }
        if options.pauseOnThermal, inputs.thermalState == .serious || inputs.thermalState == .critical {
            return .thermal
        }
        if options.pauseInLowPower, inputs.lowPowerMode { return .lowPower }
        if options.batteryFloor > 0, inputs.onBattery, inputs.batteryPercent <= options.batteryFloor {
            return .battery
        }
        return nil
    }

    /// 单块屏的结论：全局原因优先，其次看这块屏是不是被全屏应用盖住
    static func reason(
        displayKey: String,
        inputs: WallpaperPlaybackInputs,
        options: WallpaperPlaybackOptions,
        manualPause: Bool
    ) -> WallpaperPauseReason? {
        if let global = globalReason(inputs: inputs, options: options, manualPause: manualPause) {
            return global
        }
        if options.pauseOnFullscreen, inputs.fullscreenDisplays.contains(displayKey) {
            return .fullscreen
        }
        return nil
    }

    static func isPlaying(
        displayKey: String,
        inputs: WallpaperPlaybackInputs,
        options: WallpaperPlaybackOptions,
        manualPause: Bool
    ) -> Bool {
        reason(displayKey: displayKey, inputs: inputs, options: options, manualPause: manualPause) == nil
    }
}

// MARK: - 显示器身份

/// 与 WallpaperService.displayKey 同一套算法：按显示器 UUID 认屏，换口不换身份
enum WallpaperDisplay {
    static func key(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return (CFUUIDCreateString(nil, uuid) as String).uppercased()
        }
        return screen.localizedName
    }
}

// MARK: - 监听

/// 把这些外部条件变成一条条 published 的输入；策略不关心事件从哪来。
@MainActor
final class WallpaperPlaybackMonitor: ObservableObject {
    @Published private(set) var inputs = WallpaperPlaybackInputs()

    private var centerObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var pollTicks = 0
    private var isRunning = false

    deinit {
        for observer in centerObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installObservers()
        pollTicks = 0
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh(pollSlow: true)
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        for observer in centerObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        centerObservers.removeAll()
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        inputs = WallpaperPlaybackInputs()
    }

    /// 用户改了开关（比如关掉「全屏时暂停」）后立刻按新设置重算一次
    func recheck() {
        guard isRunning else { return }
        refresh(pollSlow: true)
    }

    private func installObservers() {
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mutate { $0.isLocked = true } }
        })

        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mutate { $0.isLocked = false } }
        })

        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mutate { $0.screenSaver = true } }
        })

        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mutate { $0.screenSaver = false } }
        })

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mutate { $0.displayAsleep = true } }
        })

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.mutate { $0.displayAsleep = false }
                self.refresh(pollSlow: true)
            }
        })

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mutate { $0.systemSleeping = true } }
        })

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.mutate { $0.systemSleeping = false }
                self.refresh(pollSlow: true)
            }
        })

        // 前台 App 换了，就立刻重新数一遍全屏窗口，不用等下一次轮询
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let fullscreen = Self.fullscreenDisplays()
                if fullscreen != self.inputs.fullscreenDisplays {
                    self.mutate { $0.fullscreenDisplays = fullscreen }
                }
            }
        })
    }

    private func mutate(_ change: (inout WallpaperPlaybackInputs) -> Void) {
        var next = inputs
        change(&next)
        if next != inputs { inputs = next }
    }

    private func poll() {
        pollTicks += 1
        refresh(pollSlow: pollTicks % 4 == 0)
    }

    private func refresh(pollSlow: Bool) {
        var next = inputs
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.thermalState = ProcessInfo.processInfo.thermalState
        if pollSlow {
            let battery = Self.batteryState()
            next.onBattery = battery.onBattery
            next.batteryPercent = battery.percent
        }
        next.fullscreenDisplays = Self.fullscreenDisplays()
        if next != inputs { inputs = next }
    }

    // MARK: 采样

    private static func batteryState() -> (onBattery: Bool, percent: Int) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else { return (false, 100) }
        let onBattery = (description[kIOPSPowerSourceStateKey as String] as? String) == kIOPSBatteryPowerValue
        let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 100
        let maximum = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
        let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        return (onBattery, max(0, min(100, percent)))
    }

    /// 找出被「铺满整块屏的普通窗口」盖住的显示器。
    /// 拿不到窗口信息（没有屏幕录制权限）时一律当作没盖住，宁可多播也不误停。
    static func fullscreenDisplays() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let screens = NSScreen.screens
        var covered: Set<String> = []

        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let pid = window[kCGWindowOwnerPID as String] as? Int, pid == ownPID { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 200, rect.height > 150 else { continue }

            for screen in screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let display = CGDisplayBounds(number.uint32Value)
                guard display.width > 1, display.height > 1 else { continue }
                // 允许 2pt 的边距误差：窗口通常和屏幕严丝合缝，但缩放/安全区会差一点
                let inset = display.insetBy(dx: 2, dy: 2)
                let coversOrigin = rect.contains(CGPoint(x: inset.minX, y: inset.minY))
                let coversEnd = rect.contains(CGPoint(x: inset.maxX, y: inset.maxY))
                if coversOrigin, coversEnd {
                    covered.insert(WallpaperDisplay.key(for: screen))
                    break
                }
            }
        }
        return covered
    }
}
