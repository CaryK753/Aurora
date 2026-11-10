//  PanelController.swift
//  Aurora — 液态玻璃浮动面板（NSGlassEffectView + SwiftUI 内容）

import AppKit
import SwiftUI

final class AuroraPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    static let panelSize = CGSize(width: 476, height: 664)

    private let panel: AuroraPanel
    private let glass = NSGlassEffectView()
    private let state: AppState
    private weak var anchorButton: NSStatusBarButton?
    private var transitionGeneration = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isVisible = false

    init(state: AppState) {
        self.state = state

        panel = AuroraPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        // 指针测试需要面板内的 mouseMoved 事件
        panel.acceptsMouseMovedEvents = true

        glass.style = .regular
        glass.cornerRadius = 26
        glass.tintColor = NSColor.white.withAlphaComponent(0.03)
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = false
        }
        let bounds = NSRect(origin: .zero, size: Self.panelSize)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]

        let container = NSView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        RoundedWindowSurface.configure(container, radius: 26)
        container.addSubview(glass)

        let hosting = TransparentHostingView(rootView: AuroraRootView(state: state))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting, positioned: .above, relativeTo: glass)
        hosting.translatesAutoresizingMaskIntoConstraints = true

        panel.contentView = container
        panel.invalidateShadow()

        Debug.log("panel built size=\(Self.panelSize) glass=\(glass.frame) hosting=\(hosting.frame)")

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.reposition()
            }
        }
    }

    // MARK: - 显示 / 隐藏

    func toggle(relativeTo button: NSStatusBarButton?) {
        if isVisible && panel.isVisible { hide(reason: "statusToggle") } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        anchorButton = button
        transitionGeneration += 1
        guard let origin = originForPanel(button: button) else { return }
        let target = NSRect(origin: origin, size: Self.panelSize)
        let start = NSRect(x: origin.x, y: origin.y + 10, width: Self.panelSize.width, height: Self.panelSize.height)
        Debug.log("show at \(origin)")
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // 避免搜索框在面板弹出瞬间抢到键盘焦点
        panel.makeFirstResponder(nil)
        isVisible = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        state.permissions.recheck()
        state.display.refresh(preserve: true)
        state.monitor.resume()
        installMonitors()
    }

    func hide(reason: String = "unknown") {
        guard isVisible else { return }
        Debug.log("hide reason=\(reason)")
        isVisible = false
        transitionGeneration += 1
        let generation = transitionGeneration
        removeMonitors()

        var frame = panel.frame
        frame.origin.y += 8
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isVisible, self.transitionGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func reposition() {
        guard let origin = originForPanel(button: anchorButton) else { return }
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }

    private func originForPanel(button: NSStatusBarButton?) -> CGPoint? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return nil }

        var anchorX = visibleFrame.midX
        var anchorTop = visibleFrame.maxY

        if let button, let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            anchorX = buttonRect.midX
            anchorTop = buttonRect.minY - 6
        } else if let window = panel.screen ?? screen {
            anchorTop = window.visibleFrame.maxY
        }

        var x = anchorX - Self.panelSize.width / 2
        x = max(visibleFrame.minX + 8, min(x, visibleFrame.maxX - Self.panelSize.width - 8))
        var y = anchorTop - Self.panelSize.height
        // 不越过菜单栏下沿
        y = min(y, visibleFrame.maxY - Self.panelSize.height)
        y = max(visibleFrame.minY + 8, y)
        return CGPoint(x: x, y: y)
    }

    // MARK: - 点击外部收起

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, !UserDefaults.standard.bool(forKey: "debugPinPanel") else { return }
                var statusRect: CGRect?
                if let button = self.anchorButton, let window = button.window {
                    statusRect = window.convertToScreen(button.convert(button.bounds, to: nil))
                }
                if PanelDismissalPolicy.shouldDismiss(at: location, panel: self.panel.frame, statusButton: statusRect) {
                    self.hide(reason: "outsideClick")
                }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // esc
                Task { @MainActor in self?.hide(reason: "escape") }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
