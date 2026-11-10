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
    @Published var functionKeysFirst: Bool {
        didSet {
            guard !loading else { return }
            writeBoolGlobal("com.apple.keyboard.fnState", functionKeysFirst)
        }
    }

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
        functionKeysFirst = defaults.bool(forKey: "com.apple.keyboard.fnState")
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

    // MARK: - 键盘类型

    func reloadTypes() {
        guard let dict = NSDictionary(contentsOfFile: typePlist) as? [String: Any],
              let table = dict["keyboardtype"] as? [String: Any] else {
            types = [:]
            return
        }
        var parsed: [String: Int] = [:]
        for (key, value) in table {
            if let number = value as? NSNumber { parsed[key] = number.intValue }
        }
        types = parsed
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

    // MARK: - 重复速率

    private func writeRepeat() {
        repeatTask?.cancel()
        let delay = Int(keyRepeatDelay.rounded())
        let rate = Int(keyRepeatRate.rounded())
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            shell("/usr/bin/defaults", ["write", "-g", "InitialKeyRepeat", "-int", "\(delay)"])
            shell("/usr/bin/defaults", ["write", "-g", "KeyRepeat", "-int", "\(rate)"])
        }
    }

    private func writeBoolGlobal(_ key: String, _ value: Bool) {
        shell("/usr/bin/defaults", ["write", "-g", key, "-bool", value ? "true" : "false"])
    }

    private func shell(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
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
