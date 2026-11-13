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

    /// 弹系统授权提示（只会跳一次，之后要用户自己在设置里勾）
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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

@MainActor
final class KeystrokeOverlayService {
    static let shared = KeystrokeOverlayService()

    private var monitors: [Any] = []
    private var panel: NSPanel?
    private var hosting: NSHostingView<KeystrokePillView>?
    private var fadeWork: DispatchWorkItem?

    private(set) var isGlobal = false
    /// 录制所在屏幕：按键胶囊要出现在被录的那块屏上（多屏时不跟主屏）
    var targetScreen: NSScreen?

    @discardableResult
    func start() -> Bool {
        guard monitors.isEmpty else { return isGlobal }
        isGlobal = OverlayAccess.hasAccessibility
        let mask: NSEvent.EventTypeMask = [.keyDown]

        if isGlobal, let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard !event.isARepeat else { return }
            Task { @MainActor in self?.show(event: event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if !event.isARepeat { Task { @MainActor in self?.show(event: event) } }
            return event
        }) {
            monitors.append(local)
        }
        return isGlobal
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        fadeWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        isGlobal = false
    }

    private func show(event: NSEvent) {
        guard let text = Self.displayText(for: event) else { return }

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
        let modifiers = HotkeyService.carbonModifiers(from: event.modifierFlags)
        let symbols = modifierSymbols(modifiers)

        if let named = HotkeyService.namedKeyDisplay(UInt32(event.keyCode)) {
            return symbols + named
        }
        if let character = character(for: event) {
            return symbols + character.uppercased()
        }
        return symbols.isEmpty ? nil : symbols
    }

    private static func character(for event: NSEvent) -> String? {
        // 用「忽略修饰键」的字符：⇧⌘4 显示 4（而不是 $），⇧⌘V 显示 V，
        // 系统菜单里的快捷键也是这个口径
        if let raw = event.charactersIgnoringModifiers, isPrintable(raw) {
            return raw
        }
        if let typed = event.characters, isPrintable(typed) {
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
