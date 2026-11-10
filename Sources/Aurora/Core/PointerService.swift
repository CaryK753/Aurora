//  PointerService.swift
//  Aurora — 指针与滚轮调校（事件引擎，参考 LinearMouse 的 EventTap 思路）

import AppKit
import ApplicationServices
import Combine

enum MacroAction: String, CaseIterable, Codable, Identifiable {
    case none, back, forward, missionControl, launchpad, openApplication, screenshot, mute, playPause, showDesktop, showDesktopShortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return T("无")
        case .back: return T("后退")
        case .forward: return T("前进")
        case .missionControl: return T("调度中心")
        case .launchpad: return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Apps" : T("启动台")
        case .openApplication: return T("打开应用程序…")
        case .screenshot: return T("截图到剪贴板")
        case .mute: return T("静音")
        case .playPause: return T("播放 / 暂停")
        case .showDesktop: return T("显示桌面")
        case .showDesktopShortcut: return T("显示桌面（系统快捷键）")
        }
    }

    var symbol: String {
        switch self {
        case .none: return "minus"
        case .back: return "chevron.backward"
        case .forward: return "chevron.forward"
        case .missionControl: return "rectangle.3.group"
        case .launchpad: return "square.grid.3x3"
        case .openApplication: return "app.badge"
        case .screenshot: return "camera.viewfinder"
        case .mute: return "speaker.slash"
        case .playPause: return "playpause"
        case .showDesktop: return "menubar.dock.rectangle"
        case .showDesktopShortcut: return "keyboard"
        }
    }
}

/// 按住某个修饰键时临时反转滚动方向（LinearMouse 的「修饰键反转」简化版）
enum ScrollInvertModifier: String, CaseIterable, Identifiable {
    case none, option, command, control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return T("不启用")
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        }
    }

    var flag: CGEventFlags? {
        switch self {
        case .none: return nil
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        }
    }
}

struct PointerConfig: Equatable {
    var speed: Double = 1.0        // 指针速度倍率 0.3 ... 3.0
    var acceleration: Double = 0.0 // 附加加速度 0 ... 1
    var scrollSpeed: Double = 1.0  // 滚轮速度倍率 0.3 ... 3.0
    var scrollAcceleration: Double = 0.0 // 滚得越快、走得越远 0 ... 1
    var invertScroll: Bool = false       // 兼容旧设置：同时反转鼠标与触控板
    var invertMouse: Bool = false        // 只反转滚轮鼠标（Mos 的 Reverse for mouse）
    var invertTrackpad: Bool = false     // 只反转触控板 / 妙控鼠标
    /// 平滑滚动（Mos 的核心能力）：把一格一格的滚轮事件插值成连续像素滚动
    var smoothScroll: Bool = false
    var smoothDuration: Double = 0.24    // 一次滚动铺开的时长，0.08…0.6
    /// 按住 ⌃⌥ 临时关掉平滑，方便精确定位
    var smoothBypass: Bool = true
    /// 按住 Shift 把纵向滚轮变成横向（LinearMouse / Mos 的常用开关）
    var shiftToHorizontal: Bool = false
    var modifierInvert: ScrollInvertModifier = .none
    var macroBindings: [Int: String] = [:]
    var macroApplications: [Int: String] = [:]
}

/// 滚轮插值：把离散的滚轮格数交给 120Hz 定时器逐帧发像素事件（Mos 的做法）
final class SmoothScrollAnimator: @unchecked Sendable {
    /// 打在自己发出的事件上，避免二次接管形成回环
    static let marker: Int64 = 0x4155_524F_5241

    private let queue = DispatchQueue(label: "com.cary.aurora.smooth-scroll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var targetX = 0.0, targetY = 0.0
    private var currentX = 0.0, currentY = 0.0
    private var emittedX = 0.0, emittedY = 0.0
    private var residualX = 0.0, residualY = 0.0
    private var duration: Double = 0.24
    private var lastTick: CFAbsoluteTime = 0

    func add(dx: Double, dy: Double, duration: Double) {
        queue.async {
            self.targetX += dx
            self.targetY += dy
            self.duration = min(max(duration, 0.05), 0.8)
            self.startIfNeeded()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.targetX = 0; self.targetY = 0
            self.currentX = 0; self.currentY = 0
            self.emittedX = 0; self.emittedY = 0
            self.residualX = 0; self.residualY = 0
        }
    }

    private func startIfNeeded() {
        lastTick = CFAbsoluteTimeGetCurrent()
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(max(now - lastTick, 0.001), 0.05)
        lastTick = now

        // 一阶惯性：tau ≈ 时长/3，约等于 95% 在 duration 内走完
        let tau = max(0.02, duration / 3)
        let k = 1 - exp(-dt / tau)
        currentX += (targetX - currentX) * k
        currentY += (targetY - currentY) * k

        let wantX = currentX - emittedX + residualX
        let wholeX = wantX.rounded(.towardZero)
        residualX = wantX - wholeX

        let wantY = currentY - emittedY + residualY
        let wholeY = wantY.rounded(.towardZero)
        residualY = wantY - wholeY

        if wholeX != 0 || wholeY != 0 {
            emittedX += wholeX
            emittedY += wholeY
            post(dx: wholeX, dy: wholeY)
        }

        if abs(targetX - emittedX) < 0.6, abs(targetY - emittedY) < 0.6 {
            timer?.cancel()
            timer = nil
            targetX = 0; targetY = 0
            currentX = 0; currentY = 0
            emittedX = 0; emittedY = 0
            residualX = 0; residualY = 0
        }
    }

    private func post(dx: Double, dy: Double) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cghidEventTap)
    }
}

/// 运行在事件回调线程上的引擎，不依赖主线程
final class PointerEngine: @unchecked Sendable {
    private var config = PointerConfig()
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    // 滚动残差：缩放后不足一格的位移留到下一次，避免慢速滚动掉帧
    private var residualPointX: Double = 0
    private var residualPointY: Double = 0
    private var residualLineX: Double = 0
    private var residualLineY: Double = 0
    private var smoothedVelocity: Double = 0
    private var lastScrollTime: CFTimeInterval = 0
    private let smooth = SmoothScrollAnimator()
    /// 已经吞掉按下事件的侧键，抬起时也要一起吞，避免目标 App 收到半截点击
    private var swallowedButtons = Set<Int>()
    /// 按键探测回调（Mos 那种「按一下就知道是哪个键」）
    var onButtonDetected: ((Int) -> Void)?
    var onNativeButton: ((Int) -> Bool)?
    /// 捕获模式：命中后把按键号回传，并吞掉这次事件（不触发旧映射，也不传给前台 App）
    var captureHandler: ((Int) -> Void)?
    private(set) var isCapturing = false

    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
    }

    var isRunning: Bool { tap != nil }

    func update(_ newConfig: PointerConfig) {
        lock.lock()
        config = newConfig
        lock.unlock()

        let hasMacro = onNativeButton != nil || newConfig.macroBindings.values.contains { $0 != MacroAction.none.rawValue }
        let needsEngine = newConfig.speed != 1.0 || newConfig.acceleration > 0
            || newConfig.scrollSpeed != 1.0 || newConfig.scrollAcceleration > 0
            || newConfig.invertScroll || newConfig.invertMouse || newConfig.invertTrackpad
            || newConfig.smoothScroll
            || newConfig.shiftToHorizontal
            || newConfig.modifierInvert != .none || hasMacro
            || isCapturing
        if needsEngine { start() } else { stop() }
        if !newConfig.smoothScroll { smooth.stop() }
    }

    private func currentConfig() -> PointerConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: auroraPointerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        smooth.stop()
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return Unmanaged.passUnretained(event)
        }

        let config = currentConfig()

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard config.speed != 1.0 || config.acceleration > 0 else { break }
            var dx = event.getDoubleValueField(.mouseEventDeltaX)
            var dy = event.getDoubleValueField(.mouseEventDeltaY)
            var factor = config.speed
            if config.acceleration > 0 {
                let magnitude = (dx * dx + dy * dy).squareRoot()
                factor *= 1 + config.acceleration * min(magnitude / 9.0, 1.6)
            }
            dx *= factor
            dy *= factor
            event.setDoubleValueField(.mouseEventDeltaX, value: dx)
            event.setDoubleValueField(.mouseEventDeltaY, value: dy)

        case .scrollWheel:
            if handleScroll(event: event, config: config) { return nil }

        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            onButtonDetected?(button)
            if isCapturing, button >= 2 {
                // 捕获中：这一下既不触发旧映射，也不传给前台 App
                swallowedButtons.insert(button)
                captureHandler?(button)
                return nil
            }
            if swallowedButtons.contains(button) { return nil }
            if onNativeButton?(button) == true { swallowedButtons.insert(button); return nil }
            if let raw = config.macroBindings[button],
               let action = MacroAction(rawValue: raw),
               action != .none {
                swallowedButtons.insert(button)
                let application = config.macroApplications[button]
                Task { @MainActor in MacroRunner.perform(action, applicationPath: application) }
                return nil
            }

        case .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if swallowedButtons.remove(button) != nil { return nil }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}

extension PointerEngine {
    /// 滚轮处理：速度 / 加速度 / 反转 / 平滑 / 修饰键反转 / Shift 横向
    /// 返回 true 表示这一下已经被平滑接管，原事件不要继续下发。
    ///
    /// 关键点：continuity 事件只写 pointDelta，行事件只写 delta，混着写会被 CoreGraphics
    /// 按行/点的换算关系互相覆盖（表现为 10×2 变成 16）。
    @discardableResult
    func handleScroll(event: CGEvent, config: PointerConfig) -> Bool {
        // 自己插值出来的事件直接放行，否则会无限加速
        if event.getIntegerValueField(.eventSourceUserData) == SmoothScrollAnimator.marker {
            return false
        }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        var pointY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        var pointX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var lineY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        var lineX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))

        // Shift + 纵向滚轮 → 横向（触控板本身已有横向分量时不动它）
        var swapped = false
        if config.shiftToHorizontal,
           event.flags.contains(.maskShift),
           abs(pointX) < 0.001, abs(lineX) < 0.001,
           abs(pointY) > 0.001 || abs(lineY) > 0.001 {
            swap(&pointX, &pointY)
            swap(&lineX, &lineY)
            event.flags = event.flags.subtracting(.maskShift)
            swapped = true
        }

        let magnitude = max(abs(pointY), abs(pointX), abs(lineY), abs(lineX))
        guard magnitude > 0.001 else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.004, min(now - lastScrollTime, 0.25))
        lastScrollTime = now
        // 速度用指数滑动平均，避免单帧抖动把加速度打满
        let instant = magnitude / dt
        smoothedVelocity = smoothedVelocity * 0.72 + instant * 0.28

        var factor = config.scrollSpeed
        if config.scrollAcceleration > 0 {
            // 1200 pt/s 视为「快速滚动」，最多再加 1.8 倍
            let boost = min(smoothedVelocity / 1200.0, 1.0) * 1.8
            factor *= 1 + config.scrollAcceleration * boost
        }

        // 反转：鼠标与触控板分开（Mos 的两个独立开关），旧设置 invertScroll 视为两者都反
        var sign: Double = 1
        let reversed = isContinuous ? (config.invertTrackpad || config.invertScroll)
                                    : (config.invertMouse || config.invertScroll)
        if reversed { sign = -1 }
        if let flag = config.modifierInvert.flag, event.flags.contains(flag) {
            sign *= -1
            // 反转后把修饰键从事件里摘掉，避免目标 App 再按一次修饰键解释
            event.flags = event.flags.subtracting(flag)
        }
        factor *= sign

        // 平滑只在滚轮（非连续）上做；触控板本来就有系统惯性
        let bypass = config.smoothBypass && event.flags.contains([.maskControl, .maskAlternate])
        if config.smoothScroll, !isContinuous, !bypass {
            // 非精确事件只有行数，1 行约等于 12pt，换算成像素后再插值
            let pxY = (pointY != 0 ? pointY : lineY * 12) * factor
            let pxX = (pointX != 0 ? pointX : lineX * 12) * factor
            if abs(pxX) + abs(pxY) > 0.4 {
                smooth.add(dx: pxX, dy: pxY, duration: config.smoothDuration)
                return true
            }
            return false
        }

        let needsScaling = abs(factor - 1) > 0.0001

        func scaled(_ value: Double, _ residual: inout Double) -> Int64 {
            guard value != 0 else { return 0 }
            let total = value * factor + residual
            // 加一点点 epsilon，避免 0.3×10 这种浮点误差把最后一格吞掉
            let whole = (total + (total >= 0 ? 1e-9 : -1e-9)).rounded(.towardZero)
            residual = total - whole
            return Int64(whole)
        }

        if isContinuous {
            if swapped || needsScaling {
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: scaled(pointY, &residualPointY))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: scaled(pointX, &residualPointX))
            }
        } else if swapped || needsScaling {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: scaled(lineY, &residualLineY))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: scaled(lineX, &residualLineX))
        }
        return false
    }
}

private func auroraPointerTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<PointerEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.process(type: type, event: event)
}

@MainActor
final class PointerService: ObservableObject {
    @Published var speed: Double { didSet { persist(); sync() } }
    @Published var acceleration: Double { didSet { persist(); sync() } }
    @Published var scrollSpeed: Double { didSet { persist(); sync() } }
    @Published var scrollAcceleration: Double { didSet { persist(); sync() } }
    @Published var invertScroll: Bool { didSet { persist(); sync() } }
    @Published var invertMouse: Bool { didSet { persist(); sync() } }
    @Published var invertTrackpad: Bool { didSet { persist(); sync() } }
    @Published var smoothScroll: Bool { didSet { persist(); sync() } }
    @Published var smoothDuration: Double { didSet { persist(); sync() } }
    @Published var smoothBypass: Bool { didSet { persist(); sync() } }
    @Published var shiftToHorizontal: Bool { didSet { persist(); sync() } }
    @Published var modifierInvert: ScrollInvertModifier { didSet { persist(); sync() } }
    @Published var macroApplications: [Int: String] = [:] { didSet { persist(); sync() } }
    var onNativeButton: ((Int) -> Bool)? {
        didSet { engine.onNativeButton = onNativeButton; sync() }
    }
    @Published var macroBindings: [Int: MacroAction] { didSet { persist(); sync() } }
    /// 通过捕获单独添加的按键（默认侧键 3/4 之外的）
    @Published private(set) var extraButtons: [Int] = [] { didSet { persist() } }
    /// 正在等待用户按下鼠标上的某个键
    @Published private(set) var isCapturing = false
    /// 捕获到按键的回调（用来自动解除临时固定）
    var onCaptureFinished: ((Int) -> Void)?
    /// 最近一次按下的鼠标键号：用来认出「侧键到底是 3 还是 4」
    @Published private(set) var lastPressedButton: Int?
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var engineReady: Bool = false

    private let engine = PointerEngine()
    private var moduleEnabled = true
    private var permissionGranted: Bool?
    var onPermissionRequest: (() -> Void)?
    private let defaults = UserDefaults.standard

    init() {
        speed = defaults.object(forKey: "pointer.speed") as? Double ?? 1.0
        acceleration = defaults.object(forKey: "pointer.acceleration") as? Double ?? 0.0
        scrollSpeed = defaults.object(forKey: "pointer.scrollSpeed") as? Double ?? 1.0
        scrollAcceleration = defaults.object(forKey: "pointer.scrollAcceleration") as? Double ?? 0.0
        let legacyInvert = defaults.object(forKey: "pointer.invertScroll") as? Bool ?? false
        invertScroll = legacyInvert
        invertMouse = defaults.object(forKey: "pointer.invertMouse") as? Bool ?? legacyInvert
        invertTrackpad = defaults.object(forKey: "pointer.invertTrackpad") as? Bool ?? legacyInvert
        smoothScroll = defaults.object(forKey: "pointer.smoothScroll") as? Bool ?? true
        smoothDuration = defaults.object(forKey: "pointer.smoothDuration") as? Double ?? 0.24
        smoothBypass = defaults.object(forKey: "pointer.smoothBypass") as? Bool ?? true
        shiftToHorizontal = defaults.object(forKey: "pointer.shiftToHorizontal") as? Bool ?? false
        modifierInvert = ScrollInvertModifier(
            rawValue: defaults.string(forKey: "pointer.modifierInvert") ?? ""
        ) ?? .none
        if let stored = defaults.dictionary(forKey: "pointer.macros") as? [String: String] {
            var parsed: [Int: MacroAction] = [:]
            for (key, value) in stored {
                if let button = Int(key), let action = MacroAction(rawValue: value) {
                    parsed[button] = action
                }
            }
            macroBindings = parsed
        } else {
            // 第一次运行给出 Mos 同款默认：侧键 1/2 = 后退/前进（按键号 3/4）
            macroBindings = [3: .back, 4: .forward]
        }

        macroApplications = Dictionary(uniqueKeysWithValues: (defaults.dictionary(forKey: "pointer.macroApplications") as? [String: String] ?? [:]).compactMap {
            guard let key = Int($0.key) else { return nil }; return (key, $0.value)
        })
        extraButtons = defaults.array(forKey: "pointer.extraButtons") as? [Int] ?? []
        engine.onButtonDetected = { [weak self] button in
            Task { @MainActor in self?.lastPressedButton = button }
        }
        engine.captureHandler = { [weak self] button in
            Task { @MainActor in self?.finishCapture(button) }
        }

        sync()
    }

    private func persist() {
        defaults.set(speed, forKey: "pointer.speed")
        defaults.set(acceleration, forKey: "pointer.acceleration")
        defaults.set(scrollSpeed, forKey: "pointer.scrollSpeed")
        defaults.set(scrollAcceleration, forKey: "pointer.scrollAcceleration")
        defaults.set(invertScroll, forKey: "pointer.invertScroll")
        defaults.set(invertMouse, forKey: "pointer.invertMouse")
        defaults.set(invertTrackpad, forKey: "pointer.invertTrackpad")
        defaults.set(smoothScroll, forKey: "pointer.smoothScroll")
        defaults.set(smoothDuration, forKey: "pointer.smoothDuration")
        defaults.set(smoothBypass, forKey: "pointer.smoothBypass")
        defaults.set(shiftToHorizontal, forKey: "pointer.shiftToHorizontal")
        defaults.set(modifierInvert.rawValue, forKey: "pointer.modifierInvert")
        var mapped: [String: String] = [:]
        for (button, action) in macroBindings { mapped["\(button)"] = action.rawValue }
        defaults.set(mapped, forKey: "pointer.macros")
        defaults.set(extraButtons, forKey: "pointer.extraButtons")
        defaults.set(Dictionary(uniqueKeysWithValues: macroApplications.map { (String($0.key), $0.value) }), forKey: "pointer.macroApplications")
    }

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        sync()
    }

    func setPermissionGranted(_ granted: Bool) {
        permissionGranted = granted
        sync()
    }

    func sync() {
        isTrusted = permissionGranted ?? (AXIsProcessTrusted() || CGPreflightPostEventAccess())
        guard isTrusted, moduleEnabled else {
            engine.stop()
            engineReady = false
            return
        }
        engine.update(
            PointerConfig(
                speed: speed,
                acceleration: acceleration,
                scrollSpeed: scrollSpeed,
                scrollAcceleration: scrollAcceleration,
                invertScroll: invertScroll,
                invertMouse: invertMouse,
                invertTrackpad: invertTrackpad,
                smoothScroll: smoothScroll,
                smoothDuration: smoothDuration,
                smoothBypass: smoothBypass,
                shiftToHorizontal: shiftToHorizontal,
                modifierInvert: modifierInvert,
                macroBindings: macroBindings.mapValues(\.rawValue),
                macroApplications: macroApplications
            )
        )
        engineReady = engine.isRunning
    }

    func requestPermission() {
        if let onPermissionRequest { onPermissionRequest(); return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // 轮询等待用户勾选
        Task { @MainActor in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let trusted = AXIsProcessTrusted()
                if trusted != isTrusted {
                    isTrusted = trusted
                    sync()
                }
                if trusted { break }
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func reset() {
        cancelCapture()
        speed = 1.0
        acceleration = 0.0
        scrollSpeed = 1.0
        scrollAcceleration = 0.0
        invertScroll = false
        invertMouse = false
        invertTrackpad = false
        smoothScroll = true
        smoothDuration = 0.24
        smoothBypass = true
        shiftToHorizontal = false
        modifierInvert = .none
        macroBindings = [3: .back, 4: .forward]
        macroApplications = [:]
        extraButtons = []
        lastPressedButton = nil
    }

    var isDefault: Bool {
        speed == 1.0 && acceleration == 0
            && scrollSpeed == 1.0 && scrollAcceleration == 0
            && !invertScroll && !invertMouse && !invertTrackpad && !shiftToHorizontal
            && smoothScroll && abs(smoothDuration - 0.24) < 0.001 && smoothBypass
            && modifierInvert == .none
            && macroBindings == [3: .back, 4: .forward]
            && extraButtons.isEmpty
    }

    // MARK: - 按键捕获（Mos 的「先按一下，再指定动作」）

    /// 进入捕获状态：引擎必须已经在跑，否则按下按键也没人听见
    @discardableResult
    func beginCapture() -> Bool {
        guard !isCapturing else { return true }
        guard isTrusted else {
            requestPermission()
            return false
        }
        guard engine.start() else { return false }
        isCapturing = true
        engine.setCapturing(true)
        engineReady = engine.isRunning
        return true
    }

    func cancelCapture() {
        guard isCapturing else { return }
        isCapturing = false
        engine.setCapturing(false)
        sync()
    }

    private func finishCapture(_ button: Int) {
        guard isCapturing, button >= 2, button <= 31 else { return }
        isCapturing = false
        engine.setCapturing(false)
        lastPressedButton = button
        if button != 3, button != 4, !extraButtons.contains(button) {
            extraButtons.append(button)
        }
        sync()
        onCaptureFinished?(button)
    }

    /// 列表里要显示的按键：默认侧键 + 捕获过的按键 + 已有映射
    var mappedButtons: [Int] {
        Array(Set([3, 4]).union(macroBindings.keys).union(extraButtons)).sorted()
    }

    /// 默认侧键始终留在列表里，其余捕获来的键可以移除
    func canForget(_ button: Int) -> Bool {
        button != 3 && button != 4 && extraButtons.contains(button)
    }

    func forget(_ button: Int) {
        macroBindings.removeValue(forKey: button)
        macroApplications.removeValue(forKey: button)
        extraButtons.removeAll { $0 == button }
        if lastPressedButton == button { lastPressedButton = nil }
    }

    func setMacro(_ action: MacroAction, for button: Int) {
        if action == .openApplication {
            ApplicationPicker.choose { [weak self] url in
                guard let self, let url else { return }
                self.macroApplications[button] = url.path
                self.macroBindings[button] = .openApplication
            }
            return
        }
        macroApplications.removeValue(forKey: button)
        if action == .none {
            macroBindings.removeValue(forKey: button)
        } else {
            macroBindings[button] = action
        }
    }

    var hasMacros: Bool { !macroBindings.isEmpty }
}
