//  PanelController.swift
//  Aurora — 液态玻璃面板（NSGlassEffectView + SwiftUI 内容）
//
//  两种形态：
//  · 浮动：无边框 nonactivating panel，挂在菜单栏图标下面，点外部 / Esc 收起
//  · 固定：正经的 macOS 窗口（原生红绿灯、可最小化、有窗口菜单），点外部不收起

import AppKit
import SwiftUI

final class AuroraPanel: NSPanel {
    /// 只有固定成普通窗口后才允许成为主窗口
    var allowsMain = false
    weak var headerAlignmentView: HeaderAlignmentView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { allowsMain }

    override func mouseDown(with event: NSEvent) {
        // LSUIElement 应用在运行时切成 .regular 后，macOS 点窗口不会自动激活 App
        // （窗口可能变 key 但菜单栏还停在别的应用），这里手动补上激活
        if allowsMain {
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class PanelController {
    static let panelSize = CGSize(width: 476, height: 664)
    /// 浮动面板的圆角；固定成普通窗口时收敛一点，贴近系统窗口的形状
    static let floatingCornerRadius: CGFloat = 26
    static let pinnedCornerRadius: CGFloat = 14
    /// 固定成窗口后允许拉大，但别拉成一个显示器（画廊够用就好）
    static let pinnedMaxSize = CGSize(width: 1240, height: 1080)

    private let panel: AuroraPanel
    private let glass = NSGlassEffectView()
    private let container = NSView()
    private let state: AppState
    private weak var anchorButton: NSStatusBarButton?
    private var transitionGeneration = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private(set) var isVisible = false
    private(set) var isPinned = false

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
        glass.cornerRadius = Self.floatingCornerRadius
        glass.tintColor = NSColor.white.withAlphaComponent(0.03)
        // macOS 27 SDK 才有 effectIsInteractive；用运行时探测，避免在旧 SDK 上编译失败
        if glass.responds(to: Selector(("setEffectIsInteractive:"))) {
            glass.setValue(false, forKey: "effectIsInteractive")
        }
        let bounds = NSRect(origin: .zero, size: Self.panelSize)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]

        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        RoundedWindowSurface.configure(container, radius: Self.floatingCornerRadius)
        container.addSubview(glass)

        let hosting = TransparentHostingView(rootView: AuroraRootView(state: state))
        // 由自绘顶栏统一占用顶部空间，避免 AppKit 再插入一行标题栏安全区。
        hosting.safeAreaRegions = []
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
                guard let self, self.isVisible, !self.isPinned else { return }
                self.reposition()
            }
        }

        observeWindowState()
    }

    // MARK: - 显示 / 隐藏

    func toggle(relativeTo button: NSStatusBarButton?) {
        // 固定成普通窗口后，菜单栏图标只负责把窗口叫到前面，不再收起
        if isPinned { show(relativeTo: button); return }
        if isVisible && panel.isVisible { hide(reason: "statusToggle") } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        anchorButton = button
        transitionGeneration += 1

        state.permissions.recheck()
        state.display.refresh(preserve: true)
        state.monitor.resume()
        installMonitors()

        if isPinned {
            panel.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }

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
    }

    /// force=true 用于退出 / 回到欢迎页这类必须收起面板的场合
    func hide(reason: String = "unknown", force: Bool = false) {
        guard isVisible else { return }
        guard force || !isPinned else {
            Debug.log("hide ignored, pinned reason=\(reason)")
            return
        }
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

    // MARK: - 固定 / 浮动

    /// 由 AppState 的变化驱动，不要在内部回调 state，避免绕回自身
    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        Debug.log("pinned=\(pinned)")
        applyWindowMode()
    }

    private func applyWindowMode() {
        let frame = panel.frame
        transitionGeneration += 1

        if isPinned {
            NSApp.setActivationPolicy(.regular)
            panel.allowsMain = true
            panel.isFloatingPanel = false
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            panel.title = "Aurora"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.titlebarSeparatorStyle = .none
            panel.level = .normal
            // fullScreenPrimary：绿钮 = 进入 macOS 全屏
            panel.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
            panel.becomesKeyOnlyIfNeeded = false
            panel.isMovable = true
            panel.isMovableByWindowBackground = true
            panel.minSize = Self.panelSize
            panel.maxSize = Self.pinnedMaxSize
            panel.standardWindowButton(.closeButton)?.isEnabled = true
            panel.standardWindowButton(.miniaturizeButton)?.isEnabled = true
            if let zoom = panel.standardWindowButton(.zoomButton) {
                zoom.isEnabled = true
                // 绿钮 = 全屏（zoom 行为改走 toggleFullScreen，.fullScreen 掩码不能运行时写）
                zoom.target = panel
                zoom.action = #selector(NSWindow.toggleFullScreen(_:))
            }
            applyCornerRadius(Self.pinnedCornerRadius)
            adjustTrafficLights()
            let menu = buildMainMenu()
            NSApp.mainMenu = menu
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            installMonitors()
            if isVisible {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        } else {
            if panel.styleMask.contains(.fullScreen) {
                panel.toggleFullScreen(nil)
            }
            NSApp.mainMenu = nil
            NSApp.windowsMenu = nil
            panel.allowsMain = false
            panel.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
            panel.title = ""
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.minSize = NSSize(width: 40, height: 40)
            panel.maxSize = NSSize(width: 100_000, height: 100_000)
            applyCornerRadius(Self.floatingCornerRadius)
            // 浮动面板回到固定尺寸（固定窗口可能被拉大过）
            var restore = frame
            restore.size = Self.panelSize
            panel.setFrame(restore, display: true)
            NSApp.setActivationPolicy(.accessory)
            installMonitors()
            if isVisible, panel.isVisible {
                reposition()
                // 切成 accessory 会让 App 失去活跃状态，这里再抢回一次焦点
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        }
        panel.invalidateShadow()
    }

    private func applyCornerRadius(_ radius: CGFloat) {
        glass.cornerRadius = radius
        RoundedWindowSurface.configure(container, radius: radius)
    }

    /// 固定后按 ⌘W / ⌘M / ⌘Q 才有响应，这是「像正常窗口」的一部分
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Aurora")
        let about = NSMenuItem(
            title: T("关于 Aurora"),
            action: #selector(AppDelegate.aboutFromMenu),
            keyEquivalent: ""
        )
        about.target = NSApp.delegate
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: T("设置…"),
            action: #selector(AppDelegate.settingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = NSApp.delegate
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: T("退出 Aurora"),
            action: #selector(AppDelegate.quitFromMenu),
            keyEquivalent: "q"
        )
        quit.target = NSApp.delegate
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: T("窗口"))
        windowMenu.addItem(
            withTitle: T("最小化"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: T("关闭窗口"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// 固定窗口是普通窗口，红绿灯关掉 / 最小化之后要同步可见状态，
    /// 否则再从菜单栏图标点开会被当成「已经打开」而收不起来
    private func observeWindowState() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isVisible = false }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isVisible = false }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isVisible = true }
        })
        // 拿到焦点 / 尺寸变化时 AppKit 会重排标题栏，红绿灯偏移要跟着补
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.adjustTrafficLights() }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // LSUIElement 运行时切换的 .regular：窗口 key 了 App 却没激活，补一刀
                if self.isPinned, !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
                DispatchQueue.main.async { self.adjustTrafficLights() }
            }
        })
        // 全屏：先放开 min/max（全屏尺寸会超过 pinnedMaxSize），圆角归零交给系统
        windowObservers.append(center.addObserver(
            forName: NSWindow.willEnterFullScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.panel.minSize = .zero
                self.panel.maxSize = NSSize(width: 100_000, height: 100_000)
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.isFullscreen = true
                self.applyCornerRadius(0)
                // 全屏时给窗口垫一层主题底色（跟随系统外观，60% 不透明度），
                // 否则玻璃后面透出的是被全屏的桌面，内容可读性全靠运气
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                self.panel.backgroundColor = NSColor(white: dark ? 0 : 1, alpha: 0.6)
                DispatchQueue.main.async { self.adjustTrafficLights() }
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.isFullscreen = false
                self.panel.backgroundColor = .clear
                self.applyCornerRadius(self.isPinned ? Self.pinnedCornerRadius : Self.floatingCornerRadius)
                if self.isPinned {
                    self.panel.minSize = Self.panelSize
                    self.panel.maxSize = Self.pinnedMaxSize
                }
                DispatchQueue.main.async { self.adjustTrafficLights() }
            }
        })
    }

    /// 尺寸、焦点及窗口模式变化后，重新对齐当前页面的真实顶栏中心。
    private func adjustTrafficLights() {
        panel.alignTrafficLights()
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

    // MARK: - 点击外部收起 / Esc

    private func installMonitors() {
        removeMonitors()

        if !isPinned {
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
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // esc
            let handled = MainActor.assumeIsolated { () -> Bool in
                // 捕获按键时 Esc 只负责退出捕获，不动窗口
                if self.state.pointer.isCapturing {
                    self.state.endButtonCapture()
                    return true
                }
                // 固定窗口不会被 Esc 收起来
                guard !self.isPinned else { return false }
                self.hide(reason: "escape")
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
