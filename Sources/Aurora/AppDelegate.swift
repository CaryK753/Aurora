//  AppDelegate.swift
//  Aurora — 菜单栏常驻应用

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var panelController: PanelController!
    private var welcomeController: WelcomeWindowController?
    private let state = AppState()
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
        registerHotKey()
        registerBrightnessHotKeys()
        state.onShowMainPanel = { [weak self] in self?.openPanel() }
        state.onDismissMainPanel = { [weak self] in self?.panelController.hide(reason: "welcome", force: true) }
        welcomeController = WelcomeWindowController(state: state)
        if !UserDefaults.standard.bool(forKey: "onboarding.completed")
            || UserDefaults.standard.bool(forKey: "onboarding.reopenAfterRestart") {
            UserDefaults.standard.removeObject(forKey: "onboarding.reopenAfterRestart")
            state.showWelcome = true
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

        // 每小时检查一次更新（已发过 release 才有意义，拉不到就静默失败）
        state.updates.start()

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

    /// ⌥⌘A：即使菜单栏被挤满也能唤起面板
    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                // 同一个事件目标上还挂着亮度快捷键，必须按 id 过滤
                guard hotKeyID.id == 1 else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePanel() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4155_5241), id: 1) // 'AURA'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func togglePanel() {
        panelController.toggle(relativeTo: statusItem.button)
    }

    /// ⌃⌥↑ / ⌃⌥↓：不打开面板也能调亮度（MonitorControl 的键盘亮度思路）
    private func registerBrightnessHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard hotKeyID.id == 2 || hotKeyID.id == 3 else { return noErr }
                let up = hotKeyID.id == 2
                DispatchQueue.main.async { auroraDelegate?.stepBrightness(up: up) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

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
        let display = state.display
        guard let main = display.displays.first(where: { $0.isMain }) ?? display.displays.first,
              main.hasBrightness else { return }
        let next = min(max(main.brightness + (up ? 0.06 : -0.06), 0), 1)
        display.setBrightness(next, for: main.id, animated: true)
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
        // 收掉壁纸窗口，把桌面还给系统壁纸
        state.wallpaper.teardown()
        WallpaperPreview.dismiss()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
