//  RecordingOverlays.swift
//  Aurora — 录制增强覆盖层：鼠标点击高亮 + 按键实时显示
//
//  参考 Snapzy 的 MouseClickHighlightWindow / KeystrokeOverlayWindow：
//  · 点击高亮：全局监听鼠标按下，在点击位置播放一圈扩散涟漪（会被录进画面）
//  · 按键显示：监听键盘按下，在屏幕底部浮出按键胶囊，1 秒后淡出
//    （全局键盘监听需要辅助功能权限）
//
//  两个覆盖层都放在 screenSaver 层，ScreenCaptureKit 的整屏采集会一并录进去。
//  没有辅助功能权限时只有 Aurora 自己的窗口能触发，所以对外暴露 `hasAccess`，
//  由录制页明确提示去授权，而不是「打开了但没反应」。

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// 录制覆盖层需要的系统权限
enum OverlayAccess {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 按键显示要的是「输入监控」：只读的全局键盘 tap 归这一项管，
    /// 有辅助功能权限时系统也一并放行（老系统只有辅助功能这一道门）
    static var hasKeyboardAccess: Bool { AXIsProcessTrusted() || CGPreflightListenEventAccess() }

    /// 弹系统授权提示（只会跳一次，之后要用户自己在设置里勾）
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 键盘监听走「输入监控」；没有辅助功能的话先要辅助功能（其它模块也要）
    static func requestKeyboardAccess() {
        if !AXIsProcessTrusted() { requestAccessibility() }
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 点击高亮

@MainActor
final class ClickHighlightService {
    static let shared = ClickHighlightService()

    private var monitors: [Any] = []
    private var window: NSPanel?
    private var hosting: NSHostingView<ClickRippleView>?
    private var hideWork: DispatchWorkItem?

    /// 当前是不是「全局」监听（没有辅助功能权限时只有本 App 内有效）
    private(set) var isGlobal = false

    @discardableResult
    func start() -> Bool {
        guard monitors.isEmpty else { return isGlobal }
        isGlobal = OverlayAccess.hasAccessibility
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if isGlobal, let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.ripple(at: point) }
            _ = event
        }) {
            monitors.append(global)
        }
        // 本 App 内的点击始终能收到（覆盖层窗口本身不接收鼠标，但面板里的点击算）
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.ripple(at: point) }
            return event
        }) {
            monitors.append(local)
        }
        return isGlobal
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        hideWork?.cancel()
        window?.orderOut(nil)
        window = nil
        hosting = nil
        isGlobal = false
    }

    /// 录制开始前先把窗口建出来（隐藏），这样 ScreenCaptureKit 的
    /// 「排除自身 + 例外包含覆盖层」过滤器里能有它的 window ID
    @discardableResult
    func prepare() -> CGWindowID? {
        ensurePanel()
        guard let window else { return nil }
        window.orderOut(nil)
        return CGWindowID(window.windowNumber)
    }

    private func ensurePanel() {
        guard window == nil else { return }
        let size = Self.rippleSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ClickRippleView(id: UUID()))
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: size, height: size))
        panel.contentView = hosting
        self.hosting = hosting
        window = panel
    }

    private static let rippleSize: CGFloat = 168

    private func ripple(at point: NSPoint) {
        let size = Self.rippleSize
        ensurePanel()
        guard let window, let hosting else { return }
        window.setFrameOrigin(NSPoint(x: point.x - size / 2, y: point.y - size / 2))
        window.orderFrontRegardless()
        hosting.rootView = ClickRippleView(id: UUID())

        // 动画放完就把窗口收起来，避免一片看不见的高层窗口一直压着屏幕
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak window] in window?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }
}

struct ClickRippleView: View {
    let id: UUID
    @State private var animate = false

    var body: some View {
        ZStack {
            // 深色底环：白底界面上也能看清
            Circle()
                .stroke(Color.black.opacity(0.35), lineWidth: 7)
                .scaleEffect(animate ? 1 : 0.25)
                .opacity(animate ? 0 : 0.9)
            Circle()
                .fill(AuroraTheme.accent.opacity(0.35))
                .scaleEffect(animate ? 1 : 0.2)
                .opacity(animate ? 0 : 1)
            Circle()
                .stroke(Color.white, lineWidth: 5)
                .scaleEffect(animate ? 0.95 : 0.25)
                .opacity(animate ? 0 : 1)
            Circle()
                .fill(AuroraTheme.accent)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
                .opacity(animate ? 0 : 1)
        }
        .padding(8)
        .onAppear {
            animate = false
            withAnimation(.easeOut(duration: 0.7)) { animate = true }
        }
    }
}

// MARK: - 按键显示

/// 一次按下（跨线程传值，所以先把字符解析出来，不暴露 CGEvent）
struct KeyPress: Sendable {
    var keyCode: UInt16
    var flags: CGEventFlags
    var characters: String?
    var charactersIgnoringModifiers: String?
    var isRepeat: Bool

    init(keyCode: UInt16, flags: CGEventFlags, characters: String?,
         charactersIgnoringModifiers: String?, isRepeat: Bool) {
        self.keyCode = keyCode
        self.flags = flags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.isRepeat = isRepeat
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)) }
}

/// HID 层的只读键盘 tap。
///
/// 为什么不用 `NSEvent.addGlobalMonitorForEvents`：
///  · 系统快捷键（⌘Space 聚焦搜索、⌘Tab、调度中心…）在到达全局监听之前就被拆走了，
///    监听里根本看不到；
///  · F1…F12 在「媒体键」模式下走的是 NX_SYSDEFINED（亮度 / 音量 / 播放），不是 keyDown，
///    而且 Aurora 自己的亮度接管还会把它们吞掉；
///  · Aurora 自己注册的 Carbon 热键（⌥⌘A 等）同样会消失。
/// 挂在 `.cghidEventTap` 上就能在所有这一切之前先看到一次按键，只监听（.listenOnly）不改事件。
final class KeystrokeTap: @unchecked Sendable {
    private static let systemDefinedRaw: UInt32 = 14

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onKey: ((KeyPress) -> Void)?
    /// NX_SYSDEFINED 的功能键（只在按下时回调）
    var onMedia: ((Int32) -> Void)?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << Self.systemDefinedRaw)
        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: auroraKeystrokeTapCallback,
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

    func process(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type.rawValue == Self.systemDefinedRaw {
            guard let mediaEvent = NSEvent(cgEvent: event),
                  mediaEvent.subtype.rawValue == 8 else { return }
            let key = Int32((mediaEvent.data1 & 0xFFFF_0000) >> 16)
            // 0xA 按下、0xB 抬起；按住会连发 0xA，正好可以跟手（音量 / 亮度）
            guard (mediaEvent.data1 & 0x0000_FF00) >> 8 == 0xA else { return }
            onMedia?(key)
            return
        }
        guard type == .keyDown else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // 字符交给 NSEvent 解析：跟现有按键文案逻辑同一套口径（忽略修饰键取字符）
        let nsEvent = NSEvent(cgEvent: event)
        onKey?(KeyPress(
            keyCode: keyCode,
            flags: event.flags,
            characters: nsEvent?.characters,
            charactersIgnoringModifiers: nsEvent?.charactersIgnoringModifiers,
            isRepeat: isRepeat
        ))
    }
}

private func auroraKeystrokeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeystrokeTap>.fromOpaque(userInfo).takeUnretainedValue()
    tap.process(type: type, event: event)
    // 只监听，原样放行
    return Unmanaged.passUnretained(event)
}

@MainActor
final class KeystrokeOverlayService {
    static let shared = KeystrokeOverlayService()

    private var tap: KeystrokeTap?
    private var monitors: [Any] = []
    private var panel: NSPanel?
    private var hosting: NSHostingView<KeystrokePillView>?
    private var fadeWork: DispatchWorkItem?

    private(set) var isGlobal = false
    /// 录制所在屏幕：按键胶囊要出现在被录的那块屏上（多屏时不跟主屏）
    var targetScreen: NSScreen?

    // MARK: 走查钩子（defaults write com.cary.aurora debugKeystrokeProbe -int 45）
    /// 捕获到的文案先交给这里（走查时写日志）
    var onCapture: ((String) -> Void)?
    /// 只记录、不弹胶囊
    var suppressDisplay = false

    @discardableResult
    func start() -> Bool {
        guard tap == nil, monitors.isEmpty else { return isGlobal }

        let tap = KeystrokeTap()
        tap.onKey = { [weak self] press in
            Task { @MainActor in self?.handle(press) }
        }
        tap.onMedia = { [weak self] key in
            Task { @MainActor in self?.handleMedia(key) }
        }
        if tap.start() {
            self.tap = tap
            isGlobal = true
            Debug.log("keystroke: HID tap 已挂上（全局，含系统快捷键与功能键）")
            return true
        }

        // 没有「输入监控 / 辅助功能」：退回本 App 内监听，至少录制页里点开就有反应
        Debug.log("keystroke: HID tap 不可用（缺输入监控 / 辅助功能），退回本 App 内监听")
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if !event.isARepeat { Task { @MainActor in self?.show(text: Self.displayText(for: event)) } }
            return event
        }) {
            monitors.append(local)
        }
        isGlobal = false
        return false
    }

    func stop() {
        tap?.stop()
        tap = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        fadeWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        isGlobal = false
    }

    private func handle(_ press: KeyPress) {
        guard !press.isRepeat else { return }
        show(text: Self.displayText(for: press))
    }

    private func handleMedia(_ key: Int32) {
        show(text: Self.mediaText(key: key))
    }

    private func show(text: String?) {
        guard let text else { return }
        onCapture?(text)
        guard !suppressDisplay else { return }

        ensurePanel()
        guard let panel, let hosting else { return }
        hosting.rootView = KeystrokePillView(text: text, token: UUID())

        // SwiftUI 的 fittingSize 要等下一轮布局才更新，直接按字体量文字：
        // 否则长组合键会按上一条的宽度被截断（「显示不全」就是这么来的）
        let size = Self.panelSize(for: text)
        panel.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        position(panel, size: size)
        panel.orderFrontRegardless()
        panel.alphaValue = 1

        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                panel?.animator().alphaValue = 0
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// 录制开始前先把胶囊窗口建出来（隐藏），供采集过滤器「例外包含」
    @discardableResult
    func prepare() -> CGWindowID? {
        ensurePanel()
        guard let panel else { return nil }
        panel.orderOut(nil)
        return CGWindowID(panel.windowNumber)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = CGSize(width: 160, height: 52)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: KeystrokePillView(text: "", token: UUID()))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
    }

    /// 主屏底部居中，比录制控制条再高一点
    private func position(_ panel: NSPanel, size: CGSize) {
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 118
        ))
    }

    // MARK: 组合键文案

    /// ⌃⌥⇧⌘ + 主键。方向键 / F 键 / 空格等用符号，其余用真实字符
    /// （⇧⌘V 显示 ⇧⌘V，⇧⌘4 显示 ⇧⌘4，F1 显示 F1）
    static func displayText(for event: NSEvent) -> String? {
        displayText(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.characters,
            ignoring: event.charactersIgnoringModifiers
        )
    }

    static func displayText(for press: KeyPress) -> String? {
        displayText(
            keyCode: press.keyCode,
            modifiers: press.modifierFlags,
            characters: press.characters,
            ignoring: press.charactersIgnoringModifiers
        )
    }

    static func displayText(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                            characters: String?, ignoring: String?) -> String? {
        let carbon = HotkeyService.carbonModifiers(from: modifiers)
        let symbols = modifierSymbols(carbon)

        if let named = HotkeyService.namedKeyDisplay(UInt32(keyCode)) {
            return symbols + named
        }
        if let character = character(characters: characters, ignoring: ignoring) {
            return symbols + character.uppercased()
        }
        return symbols.isEmpty ? nil : symbols
    }

    /// 功能键在「媒体键」模式下走 NX_SYSDEFINED，只有按下才显示一次；
    /// 认不出来的（比如键盘上的特殊键）直接不显示，别弹一个空胶囊
    static func mediaText(key: Int32) -> String? {
        switch key {
        case 0: return "🔊 +"        // 音量 +
        case 1: return "🔊 −"        // 音量 −
        case 7: return "🔇"          // 静音
        case 2: return "🔆"          // 亮度 +
        case 3: return "🔅"          // 亮度 −
        case 16: return "⏯"          // 播放 / 暂停
        case 17: return "⏭"          // 下一曲
        case 18: return "⏮"          // 上一曲
        case 19: return "⏩"
        case 20: return "⏪"
        case 21: return "⌨︎ +"       // 键盘背光 +
        case 22: return "⌨︎ −"
        case 23: return "⌨︎"
        case 14: return "⏏"          // 退盘
        default: return nil
        }
    }

    private static func character(characters: String?, ignoring: String?) -> String? {
        // 用「忽略修饰键」的字符：⇧⌘4 显示 4（而不是 $），⇧⌘V 显示 V，
        // 系统菜单里的快捷键也是这个口径
        if let raw = ignoring, isPrintable(raw) {
            return raw
        }
        if let typed = characters, isPrintable(typed) {
            return typed
        }
        return nil
    }

    private static func modifierSymbols(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    private static func isPrintable(_ text: String) -> Bool {
        guard !text.isEmpty, let scalar = text.unicodeScalars.first else { return false }
        if CharacterSet.controlCharacters.contains(scalar) { return false }
        // 功能键 / 方向键在 characters 里是 U+F700 段私有区字符
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return true
    }

    private static let pillFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 21, weight: .semibold)
        if let descriptor = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: 21) {
            return rounded
        }
        return base
    }()

    /// 按字体量出来的面板尺寸（含胶囊内边距与余量）
    static func panelSize(for text: String) -> CGSize {
        let width = (text as NSString).size(withAttributes: [.font: pillFont]).width
        return CGSize(width: ceil(width) + 54, height: 50)
    }
}

struct KeystrokePillView: View {
    let text: String
    let token: UUID

    var body: some View {
        Text(text)
            .font(.system(size: 21, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background {
                // 深底白字：比之前的毛玻璃在浅色界面 / 视频上清楚得多
                Capsule().fill(Color.black.opacity(0.78))
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .fixedSize()
            .id(token)
    }
}
