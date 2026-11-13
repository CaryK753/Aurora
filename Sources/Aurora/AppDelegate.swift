//  AppDelegate.swift
//  Aurora — 菜单栏常驻应用

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var welcomeController: WelcomeWindowController?
    private var whatsNewController: WhatsNewWindowController?
    private var logitechSetupController: LogitechSetupWindowController?
    let state = AppState()
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        let overview = NSMenuItem(title: T("打开 Aurora"), action: #selector(openPanel), keyEquivalent: "")
        overview.target = self
        menu.addItem(overview)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: T("退出 Aurora"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 所有原生弹窗（popover / sheet）都要高于主面板
        PopupLevelMonitor.install()

        panelController = PanelController(state: state)
        // 固定的开关由面板右上角的按钮控制，这里只负责把窗口形态交给 PanelController
        state.onSetPinned = { [weak self] pinned in self?.panelController.setPinned(pinned) }
        setupStatusItem()
        MacroRunner.startObservingApplications()
        MacroRunner.dismissPanel = { [weak self] in self?.panelController.hide(reason: "macro") }
        MacroRunner.onError = { [weak self] message in
            self?.state.showToast(message, symbol: "exclamationmark.triangle")
            self?.panelController.show(relativeTo: self?.statusItem.button)
        }
        MacroRunner.toggleMute = { [weak self] in
            guard let self else { return }
            self.state.audio.refresh()
            guard let device = self.state.audio.outputs.first(where: \.isDefault) else { return }
            self.state.audio.toggleMute(device)
        }
        registerHotKeys()
        registerBrightnessHotKeys()
        MiniClipboardController.shared.clipboard = state.clipboard
        Debug.log("caret locator: \(CaretLocator.availability())")
        state.onShowMainPanel = { [weak self] in self?.openPanel() }
        state.onDismissMainPanel = { [weak self] in self?.panelController.hide(reason: "welcome", force: true) }
        welcomeController = WelcomeWindowController(state: state)
        // 更新后的第一次启动：介绍这一版的新功能（每个版本一次）
        whatsNewController = WhatsNewWindowController(state: state)
        // 检测到罗技鼠标时（可能早在 AppState 初始化时就登记了）把向导窗口准备好
        logitechSetupController = LogitechSetupWindowController(state: state)
        if !UserDefaults.standard.bool(forKey: "onboarding.completed")
            || UserDefaults.standard.bool(forKey: "onboarding.reopenAfterRestart") {
            UserDefaults.standard.removeObject(forKey: "onboarding.reopenAfterRestart")
            state.showWelcome = true
        }
        presentWhatsNewIfNeeded()

        // 设计走查：defaults write com.cary.aurora debugMiniClipboard -bool YES 后启动，
        // 直接把 mini 剪切板弹出来看效果（看完自动清掉这个键）
        if UserDefaults.standard.bool(forKey: "debugMiniClipboard") {
            UserDefaults.standard.removeObject(forKey: "debugMiniClipboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MiniClipboardController.shared.show()
            }
        }
        if let raw = UserDefaults.standard.string(forKey: "debugTab"),
           let module = AuroraModule(rawValue: raw) {
            state.module = module
        }
        if UserDefaults.standard.bool(forKey: "debugImport") {
            state.imports.scan(displays: state.display.displays)
            state.showImport = true
        }

        // 之前开启过动态壁纸的话，登录后自动恢复
        state.wallpaper.activateIfNeeded()

        // 开发调试：AURORA_WALLPAPER_PROC=1 直接应用第一张程序化壁纸
        if ProcessInfo.processInfo.environment["AURORA_WALLPAPER_PROC"] == "1",
           let item = state.wallpapers.items.first(where: { $0.kind == .procedural }) {
            state.wallpaper.setEnabled(true)
            state.wallpaper.useAsWallpaper(item)
            Debug.log("debug: applied procedural wallpaper \(item.name)")
        }

        // 每小时检查一次更新（已发过 release 才有意义，拉不到就静默失败）
        state.updates.start()

        // 节能定时结束后给一条系统通知
        NotificationCenter.default.addObserver(
            forName: .auroraEnergyFinished, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in NotificationService.shared.notifyEnergyFinished() }
        }

        if ProcessInfo.processInfo.environment["AURORA_OPEN_PANEL"] == "1"
            || UserDefaults.standard.bool(forKey: "debugOpenPanel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.panelController.show(relativeTo: self.statusItem.button)
            }
        }
        // 开发调试：AURORA_OPEN_WALLPAPER=1 打开面板并进壁纸页
        if ProcessInfo.processInfo.environment["AURORA_OPEN_WALLPAPER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.state.showWelcome = false
                self.panelController.show(relativeTo: self.statusItem.button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.state.showWallpaper = true
                }
            }
        }
        // 开发走查：defaults write com.cary.aurora debugCameraBubble -bool YES 后启动，
        // 只把画中画气泡摆出来（不录屏），用来核对样式、拖动与缩放
        if UserDefaults.standard.bool(forKey: "debugCameraBubble") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CameraBubble.shared.show(on: RecorderService.shared.targetScreen)
            }
        }
        // 开发走查：defaults write com.cary.aurora debugRecordPip 6 后启动，
        // 自动打开画中画录一段（保留文件，供抽帧核对气泡有没有进画面）
        if let raw = UserDefaults.standard.object(forKey: "debugRecordPip") {
            UserDefaults.standard.removeObject(forKey: "debugRecordPip")
            let seconds = (raw as? Double) ?? Double(raw as? Int ?? 6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let recorder = RecorderService.shared
                let previous = recorder.pipCamera
                recorder.pipCamera = true
                recorder.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    recorder.stop()
                    recorder.pipCamera = previous
                }
            }
        }
    }

    /// 更新后的第一次启动弹「新功能」；这一版没有说明就静默记下，不打扰
    private func presentWhatsNewIfNeeded() {
        let defaults = UserDefaults.standard
        // 设计走查：defaults write com.cary.aurora debugWhatsNew -bool YES（下次启动生效）
        if defaults.bool(forKey: "debugWhatsNew") {
            defaults.removeObject(forKey: "debugWhatsNew")
            defaults.removeObject(forKey: ReleaseNotesStore.seenVersionKey)
        }
        guard defaults.bool(forKey: "onboarding.completed"),
              ReleaseNotesStore.shouldShow() else { return }
        guard ReleaseNotesStore.notes() != nil else {
            Debug.log("whatsnew: no notes for \(ReleaseNotesStore.currentVersion), skipped")
            ReleaseNotesStore.markSeen()
            return
        }
        Debug.log("whatsnew: \(ReleaseNotesStore.currentVersion) unseen, will present")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.state.showWelcome else { return }
            self.state.showWhatsNew = true
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Aurora")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        statusItem.behavior = .removalAllowed
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = T("Aurora · 桌面控制台")
        button.target = self
        button.action = #selector(handleStatusClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let window = button.window else { return }
            let onScreen = window.occlusionState.contains(.visible)
            Debug.log("statusItem onScreen=\(onScreen) frame=\(window.frame)")
        }
    }

    @objc private func handleStatusClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panelController.toggle(relativeTo: statusItem.button)
        }
    }

    /// 可配置热键（面板 / mini 剪切板），交给 HotkeyService 统一注册
    private func registerHotKeys() {
        state.hotkeys.onAction = { [weak self] action in
            switch action {
            case .panel:
                self?.togglePanel()
            case .miniClipboard:
                MiniClipboardController.shared.toggle()
            case .screenshot:
                ScreenshotSession.shared.startRegionCapture()
            case .recorder:
                RecorderService.shared.toggle()
            }
        }
        state.hotkeys.registerAll()
    }

    func togglePanel() {
        panelController.toggle(relativeTo: statusItem.button)
    }

    /// 截图开始前把主面板收起来，避免把 Aurora 自己截进画面
    func panelWillCaptureScreenshot() {
        panelController.hide(reason: "screenshot", force: true)
    }

    /// ⌃⌥↑ / ⌃⌥↓：不打开面板也能调亮度（MonitorControl 的键盘亮度思路）
    /// 注意：只注册热键，不再单独 InstallEventHandler——全部热键事件由
    /// HotkeyService 的唯一处理器分发（onBrightness / onAction），
    /// 否则后装的处理器会把其它热键的事件吞掉。
    private func registerBrightnessHotKeys() {
        state.hotkeys.onBrightness = { [weak self] up in
            self?.stepBrightness(up: up)
        }

        for (index, key) in [(2, UInt32(kVK_UpArrow)), (3, UInt32(kVK_DownArrow))] {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4155_5241), id: UInt32(index))
            let status = RegisterEventHotKey(
                key,
                UInt32(controlKey | optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            Debug.log("brightness hotkey id=\(index) status=\(status)")
        }
    }

    func stepBrightness(up: Bool) {
        // 走 DisplayService 的步进：跟随鼠标所在屏 / 多屏同步 / OSD 都在里面
        let fine = NSEvent.modifierFlags.contains([.option, .shift])
        _ = state.display.stepBrightness(up: up, fine: fine)
    }

    @objc private func openPanel() {
        panelController.show(relativeTo: statusItem.button)
    }

    @objc private func quit() {
        state.requestQuit()
    }

    /// 固定窗口菜单栏里的「关于」
    @objc func aboutFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [:])
    }

    /// 固定窗口菜单栏里的「设置」：打开面板并跳到设置模块
    @objc func settingsFromMenu() {
        panelController.show(relativeTo: statusItem.button)
        state.select(.settings)
    }

    /// 固定成普通窗口后，菜单栏里的「退出 Aurora」也走同一套确认流程
    @objc func quitFromMenu() {
        state.requestQuit()
    }

    /// 固定状态下点 Dock 图标：把窗口叫回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { panelController.show(relativeTo: statusItem.button) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 拆除按应用音量的 tap，避免退出瞬间把正在播放的声音吞掉
        state.logitech.shutdown()
        state.appAudio.shutdown()
        // 还原软件调光，别把桌面留在被压暗的状态
        state.display.shutdown()
        // 收掉壁纸窗口，把桌面还给系统壁纸
        state.wallpaper.teardown()
        WallpaperPreview.dismiss()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
