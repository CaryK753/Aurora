//  RecordingOverlays.swift
//  Aurora — 录制增强覆盖层：鼠标点击高亮 + 按键实时显示
//
//  参考 Snapzy 的 MouseClickHighlightWindow / KeystrokeOverlayWindow：
//  · 点击高亮：全局监听鼠标按下，在点击位置播放一圈扩散涟漪（会被录进画面）
//  · 按键显示：监听键盘按下，在屏幕底部浮出按键胶囊，1 秒后淡出
//    （全局键盘监听需要辅助功能权限）
//
//  覆盖层放在 screenSaver 层，ScreenCaptureKit 的整屏采集会一并录进去。

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 点击高亮

@MainActor
final class ClickHighlightService {
    static let shared = ClickHighlightService()

    private var monitors: [Any] = []
    private var window: NSWindow?
    private var hosting: NSHostingView<ClickRippleView>?

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.ripple() }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.ripple() }
            return event
        })
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        window?.orderOut(nil)
    }

    private func ripple() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let size: CGFloat = 96
        if window == nil {
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
        guard let window, let hosting else { return }
        // NS 全局坐标（左下原点）→ 窗口左上角
        let origin = NSPoint(
            x: point.x - size / 2,
            y: point.y - size / 2
        )
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        // 重置动画：换一个 id 让 SwiftUI 重建视图
        hosting.rootView = ClickRippleView(id: UUID())
    }
}

struct ClickRippleView: View {
    let id: UUID
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AuroraTheme.accent.opacity(0.30))
                .scaleEffect(animate ? 1 : 0.2)
                .opacity(animate ? 0 : 1)
            Circle()
                .stroke(AuroraTheme.accent, lineWidth: 3.5)
                .scaleEffect(animate ? 1 : 0.3)
                .opacity(animate ? 0 : 0.95)
            Circle()
                .fill(AuroraTheme.accent.opacity(0.5))
                .frame(width: 14, height: 14)
                .opacity(animate ? 0 : 1)
        }
        .padding(6)
        .onAppear {
            animate = false
            withAnimation(.easeOut(duration: 0.55)) { animate = true }
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

    func start() {
        guard monitors.isEmpty else { return }
        // 全局键盘监听需要辅助功能权限；没有就静默不启用
        guard AXIsProcessTrusted() else {
            Debug.log("keystroke overlay skipped: accessibility not granted")
            return
        }
        let mask: NSEvent.EventTypeMask = [.keyDown]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.show(event: event) }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.show(event: event) }
            return event
        })
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        fadeWork?.cancel()
        panel?.orderOut(nil)
    }

    private func show(event: NSEvent) {
        // 密码框等安全输入不显示
        if event.charactersIgnoringModifiers == nil { return }
        let text = HotkeyService.displayString(
            keyCode: UInt32(event.keyCode),
            modifiers: HotkeyService.carbonModifiers(from: event.modifierFlags),
            fallback: event.charactersIgnoringModifiers
        )
        guard !text.isEmpty else { return }

        ensurePanel()
        guard let panel else { return }
        if let hosting {
            hosting.rootView = KeystrokePillView(text: text, token: UUID())
        }
        position(panel)
        panel.orderFrontRegardless()
        panel.alphaValue = 1

        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel?.animator().alphaValue = 0
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = CGSize(width: 260, height: 52)
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

    /// 主屏底部居中，比录制控制条高一些
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 92
        ))
    }
}

struct KeystrokePillView: View {
    let text: String
    let token: UUID

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Capsule().fill(.ultraThickMaterial)
            }
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .transition(.opacity)
            .id(token)
    }
}
