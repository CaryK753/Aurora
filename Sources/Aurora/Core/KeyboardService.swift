//  KeyboardService.swift
//  Aurora — 键盘：设备识别、键盘类型、重复速率、按键测试与「清洁模式」
//
//  清洁模式会临时吞掉所有键盘事件（鼠标不受影响），只保留 ⌃⌥⌘K 作为解锁手势，
//  同时有一个悬浮窗可以点按钮解锁，并在 5 分钟后自动解除，避免把键盘锁死。

import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum KeyboardType: Int, CaseIterable, Identifiable {
    case auto = 0
    case ansi = 40
    case iso = 41
    case jis = 42

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto: return T("自动")
        case .ansi: return "ANSI"
        case .iso: return "ISO"
        case .jis: return "JIS"
        }
    }

    var detail: String {
        switch self {
        case .auto: return T("由系统识别")
        case .ansi: return T("美式 · 长条回车")
        case .iso: return T("欧式 · 大 L 回车")
        case .jis: return T("日式 · 多两键")
        }
    }
}

// MARK: - 清洁模式的键盘事件拦截

final class CleanKeyboardEngine: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onUnlock: (() -> Void)?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: auroraCleanTapCallback,
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
    }

    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        // ⌃⌥⌘K：唯一的解锁手势，误触概率极低
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if code == 0x28,
               flags.contains(.maskControl),
               flags.contains(.maskAlternate),
               flags.contains(.maskCommand) {
                let callback = onUnlock
                DispatchQueue.main.async { callback?() }
            }
        }
        return nil // 其余按键全部吞掉
    }
}

private func auroraCleanTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return nil }
    let engine = Unmanaged<CleanKeyboardEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.process(type: type, event: event)
}

/// Fn / 🌐 键功能（对应系统 keyboard › 「按 🌐 键时」）
enum FnKeyUsage: Int, CaseIterable, Identifiable {
    case doNothing = 0
    case changeInputSource = 1
    case emoji = 2
    case dictation = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .doNothing: return T("不做任何事")
        case .changeInputSource: return T("切换输入法")
        case .emoji: return T("显示表情与符号")
        case .dictation: return T("启动听写")
        }
    }

    var symbol: String {
        switch self {
        case .doNothing: return "circle.slash"
        case .changeInputSource: return "character.cursor.ibeam"
        case .emoji: return "face.smiling"
        case .dictation: return "mic"
        }
    }
}

// MARK: - 服务

@MainActor
final class KeyboardService: ObservableObject {
    /// 每个键盘的 com.apple.keyboardtype 记录（键：ProductID-VendorID-0）
    @Published private(set) var types: [String: Int] = [:]
    @Published private(set) var cleanMode = false
    @Published private(set) var cleanRemaining = 0

    @Published var keyRepeatDelay: Double {
        didSet { guard !loading else { return }; writeRepeat() }
    }
    @Published var keyRepeatRate: Double {
        didSet { guard !loading else { return }; writeRepeat() }
    }
    /// F1–F12 直接作为标准功能键（系统「Use F1, F2, etc. keys as standard function keys」）
    @Published var functionKeysFirst: Bool {
        didSet {
            guard !loading else { return }
            applyFunctionKeys(functionKeysFirst)
        }
    }
    /// Fn / 🌐 键的功能（com.apple.HIToolbox AppleFnUsageType）
    @Published var fnUsage: FnKeyUsage {
        didSet {
            guard !loading else { return }
            applyFnUsage(fnUsage)
        }
    }
    /// 功能键设置是否真的落到系统里（回读校验的结果）
    @Published private(set) var functionKeysVerified = true

    var onToast: ((String, String) -> Void)?
    var onRequestPermission: (() -> Void)?

    private let engine = CleanKeyboardEngine()
    private let defaults = UserDefaults.standard
    private var cleanDeadline: Date?
    private var cleanTimer: Timer?
    private var repeatTask: Task<Void, Never>?
    private var hud: CleanModePanel?
    private var moduleEnabled = true
    private let cleanLimit: TimeInterval = 300
    private var loading = false

    private let typePlist = "/Library/Preferences/com.apple.keyboardtype.plist"

    init() {
        loading = true
        let delay = defaults.object(forKey: "InitialKeyRepeat") as? Double ?? 25
        let rate = defaults.object(forKey: "KeyRepeat") as? Double ?? 6
        keyRepeatDelay = min(max(delay, 10), 60)
        keyRepeatRate = min(max(rate, 1), 12)
        functionKeysFirst = Self.readFunctionKeys()
        fnUsage = FnKeyUsage(rawValue: Self.readFnUsage()) ?? .doNothing
        loading = false
        reloadTypes()

        engine.onUnlock = { [weak self] in
            Task { @MainActor in self?.stopCleaning(reason: "shortcut") }
        }
    }

    deinit {
        cleanTimer?.invalidate()
        repeatTask?.cancel()
        engine.stop()
    }

    private let typeWorker = BackgroundSnapshot<String, [String: Int]>(label: "aurora.keyboard.types") { path in
        guard let data = FileManager.default.contents(atPath: path),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let table = dict["keyboardtype"] as? [String: Any] else { return [:] }
        return table.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    // MARK: - 键盘类型

    func reloadTypes() {
        let path = typePlist
        typeWorker.requestLatest(path) { [weak self] parsed in
            guard let self, self.types != parsed else { return }
            self.types = parsed
        }
    }

    func storedType(for device: HIDDevice) -> KeyboardType {
        guard device.canSetType, let raw = types[device.keyboardTypeKey] else { return .auto }
        return KeyboardType(rawValue: raw) ?? .auto
    }

    /// 写 /Library/Preferences 需要管理员授权，会弹一次系统密码框
    func applyType(_ type: KeyboardType, for device: HIDDevice) {
        guard device.canSetType else {
            onToast?(T("内建键盘的类型由硬件决定，无需设置"), "exclamationmark.triangle")
            return
        }
        let key = device.keyboardTypeKey
        let command: String
        if type == .auto {
            command = "/usr/libexec/PlistBuddy -c \"Delete :keyboardtype:\(key)\" \(typePlist) || true"
        } else {
            command = "/usr/bin/defaults write /Library/Preferences/com.apple.keyboardtype keyboardtype -dict-add '\(key)' -int \(type.rawValue)"
        }

        runAdmin(command) { [weak self] ok, message in
            guard let self else { return }
            if ok {
                self.reloadTypes()
                self.onToast?(T("键盘类型已更新，重新连接键盘后生效"), "keyboard")
            } else {
                Debug.log("keyboard type failed: \(message)")
                if !message.localizedCaseInsensitiveContains("cancel") {
                    self.onToast?(T("没有写入键盘类型，可稍后再试"), "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - 系统键盘偏好

    private func writeRepeat() {
        repeatTask?.cancel()
        let delay = Int(keyRepeatDelay.rounded())
        let rate = Int(keyRepeatRate.rounded())
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            let savedDelay = writePreference("InitialKeyRepeat", NSNumber(value: delay))
            let savedRate = writePreference("KeyRepeat", NSNumber(value: rate))
            if !savedDelay || !savedRate {
                loading = true
                keyRepeatDelay = (Self.readPreference("InitialKeyRepeat")?.doubleValue ?? 25)
                keyRepeatRate = (Self.readPreference("KeyRepeat")?.doubleValue ?? 6)
                loading = false
                onToast?(T("键盘设置未保存，请在系统设置中重试"), "exclamationmark.triangle")
            } else {
                onToast?(T("已保存键盘设置，可能需要重新登录后生效"), "keyboard")
            }
        }
    }

    nonisolated private static func readPreference(_ key: String, domain: CFString = kCFPreferencesAnyApplication) -> NSNumber? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
    }

    private func writePreference(_ key: String, _ value: NSNumber, domain: CFString = kCFPreferencesAnyApplication) -> Bool {
        let old = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(key as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let synced = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard synced, Self.readPreference(key, domain: domain) == value else {
            CFPreferencesSetValue(key as CFString, old, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            return false
        }
        return true
    }

    nonisolated static func readFunctionKeys() -> Bool {
        Self.readPreference("com.apple.keyboard.fnState", domain: "com.apple.keyboard" as CFString)?.boolValue
            ?? Self.readPreference("com.apple.keyboard.fnState")?.boolValue ?? false
    }

    nonisolated static func readFnUsage() -> Int {
        Self.readPreference("AppleFnUsageType", domain: "com.apple.HIToolbox" as CFString)?.intValue ?? 0
    }

    private func applyFunctionKeys(_ on: Bool) {
        let key = "com.apple.keyboard.fnState"
        let globalSaved = writePreference(key, NSNumber(value: on))
        let domainSaved = writePreference(key, NSNumber(value: on), domain: "com.apple.keyboard" as CFString)
        functionKeysVerified = globalSaved && domainSaved && Self.readFunctionKeys() == on
        if !functionKeysVerified {
            loading = true
            functionKeysFirst = Self.readFunctionKeys()
            loading = false
            onToast?(T("功能键设置没有写进系统，可改用系统设置里的同名开关"), "exclamationmark.triangle")
        } else {
            onToast?(T("已保存键盘设置，可能需要重新登录后生效"), "keyboard")
        }
    }

    private func applyFnUsage(_ usage: FnKeyUsage) {
        guard writePreference("AppleFnUsageType", NSNumber(value: usage.rawValue), domain: "com.apple.HIToolbox" as CFString) else {
            loading = true
            fnUsage = FnKeyUsage(rawValue: Self.readFnUsage()) ?? .doNothing
            loading = false
            onToast?(T("键盘设置未保存，请在系统设置中重试"), "exclamationmark.triangle")
            return
        }
        onToast?(T("已保存键盘设置，可能需要重新登录后生效"), "globe")
    }

    private func runAdmin(_ command: String, completion: @escaping (Bool, String) -> Void) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in completion(proc.terminationStatus == 0, text) }
        }
        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    // MARK: - 清洁模式

    var cleanAvailable: Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        if !enabled, cleanMode { stopCleaning(reason: "module") }
    }

    @discardableResult
    func startCleaning() -> Bool {
        guard !cleanMode else { return true }
        guard moduleEnabled else { return false }
        guard cleanAvailable else {
            onRequestPermission?()
            onToast?(T("清洁键盘需要辅助功能权限"), "lock.shield")
            return false
        }
        guard engine.start() else {
            onToast?(T("无法拦截键盘事件，请检查辅助功能权限"), "exclamationmark.triangle")
            return false
        }

        cleanMode = true
        cleanDeadline = Date().addingTimeInterval(cleanLimit)
        cleanRemaining = Int(cleanLimit)
        showHUD()

        cleanTimer?.invalidate()
        cleanTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCleaning() }
        }
        return true
    }

    func stopCleaning(reason: String = "user") {
        guard cleanMode else { return }
        cleanMode = false
        cleanDeadline = nil
        cleanRemaining = 0
        cleanTimer?.invalidate()
        cleanTimer = nil
        engine.stop()
        hideHUD()
        if reason == "user" {
            onToast?(T("键盘已解锁"), "keyboard")
        } else if reason == "auto" {
            onToast?(T("已自动解锁键盘"), "lock.open")
        }
    }

    private func tickCleaning() {
        guard let deadline = cleanDeadline else { return }
        let left = Int(deadline.timeIntervalSinceNow.rounded())
        cleanRemaining = max(0, left)
        if left <= 0 { stopCleaning(reason: "auto") }
    }

    private func showHUD() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = CleanModePanel(content: CleanModeHUDView(service: self))
        let size = CGSize(width: 348, height: 104)
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
        hud = panel
    }

    private func hideHUD() {
        guard let hud else { return }
        self.hud = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hud.animator().alphaValue = 0
        } completionHandler: {
            hud.orderOut(nil)
        }
    }
}

// MARK: - 清洁模式悬浮窗

private final class CleanModePanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 104),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .init(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false

        let hosting = TransparentHostingView(rootView: content)
        RoundedWindowSurface.configure(hosting, radius: 18)
        hosting.frame = NSRect(x: 0, y: 0, width: 348, height: 104)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CleanModeHUDView: View {
    @ObservedObject var service: KeyboardService

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AuroraTheme.warn.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AuroraTheme.warn)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(T("键盘已锁定"))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(TF("可直接擦拭键盘 · %@ 后自动解锁", timeLeft))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            VStack(spacing: 4) {
                Button {
                    service.stopCleaning()
                } label: {
                    Text(T("解锁"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AuroraTheme.accentGradient))
                }
                .buttonStyle(.plain)

                Text("⌃⌥⌘K")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(6)
    }

    private var timeLeft: String {
        let seconds = max(service.cleanRemaining, 0)
        return seconds >= 60
            ? TF("%d 分 %d 秒", seconds / 60, seconds % 60)
            : TF("%d 秒", seconds)
    }
}
