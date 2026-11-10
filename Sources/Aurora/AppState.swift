//  AppState.swift
//  Aurora — 全局状态

import AppKit
import LogitechPlugin
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var module: AuroraModule = .overview
    @Published var showImport = false
    @Published var showWelcome = false
    var onShowMainPanel: (() -> Void)?
    var onDismissMainPanel: (() -> Void)?

    /// 欢迎页点「开始使用」后，从菜单栏图标位置弹出主面板。
    /// 欢迎窗正在收起，直接同步弹出会被当成「点在面板外面」而立刻收起，
    /// 所以等一个 runloop 周期，并把 App 重新激活，保证面板能正常拿到焦点。
    func presentMainPanel(after delay: TimeInterval = 0.12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.onShowMainPanel?()
        }
    }

    /// 从设置页打开欢迎页：先收起浮动面板，再把焦点交给欢迎窗
    func openWelcome() {
        onDismissMainPanel?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.showWelcome = true
        }
    }

    func dismissMainPanel() {
        onDismissMainPanel?()
    }

    /// 统一的退出入口：默认先问一句，用户勾了「不再询问」就直接退出
    func requestQuit() {
        guard AuroraAlert.confirmQuit() else { return }
        NSApp.terminate(nil)
    }
    @Published private(set) var toast: String?
    @Published private(set) var toastSymbol: String = "checkmark.circle.fill"
    @Published private(set) var languageToken = 0

    let display = DisplayService()
    let pointer = PointerService()
    let logitech = LogitechDeviceService()
    let trackpad = TrackpadService()
    let keyboard = KeyboardService()
    let hid = HIDDeviceService()
    let devices = DeviceService()
    let screenTest = ScreenTestService.shared
    let contextMenu = ContextMenuService()
    let monitor = SystemMonitor()
    let networkProcesses = NetworkProcessSampler()
    let speedTest = SpeedTester()
    let desktop = DesktopService()
    let imports = ImportService()
    let customActions = CustomActionService()
    let clipboard = ClipboardService()
    let energy = EnergyService()
    let audio = AudioService()
    let appAudio = PerAppAudioService()
    let ai = AIUsageService()
    let finderExt = FinderExtensionService()
    let updates = UpdateService()
    let settings: SettingsService
    let permissions = PermissionService()

    private var toastTask: Task<Void, Never>?
    private var languageObserver: NSObjectProtocol?
    private var batterySink: AnyCancellable?
    private var permissionSink: AnyCancellable?
    private var hardwareSink: AnyCancellable?
    private var moduleSink: AnyCancellable?
    private var settingsSink: AnyCancellable?

    /// preview=true：离屏渲染/快照用，外观等偏好只存在内存里，不污染真实设置
    init(preview: Bool = false) {
        settings = SettingsService(persistPreferences: !preview)
        if !preview {
            hardwareSink = trackpad.$hasHardware.removeDuplicates().sink { [weak self] available in
                guard let self, !UserDefaults.standard.bool(forKey: "settings.trackpadUserChoice") else { return }
                self.settings.setModule(.trackpad, enabled: available, userInitiated: false)
            }
        }
        settingsSink = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        moduleSink = settings.$disabledModules.sink { [weak self] disabled in
            guard let self else { return }
            self.pointer.setModuleEnabled(!disabled.contains("pointer"))
            self.logitech.setModuleEnabled(!disabled.contains("pointer"))
            self.clipboard.setModuleEnabled(!disabled.contains("clipboard"))
            self.energy.setModuleEnabled(!disabled.contains("energy"))
            self.appAudio.setModuleEnabled(!disabled.contains("audio"))
            self.keyboard.setModuleEnabled(!disabled.contains("keyboard"))
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .auroraLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.languageToken += 1
                self.objectWillChange.send()
            }
        }

        permissionSink = permissions.$accessibility
            .removeDuplicates()
            .sink { [weak self] granted in
                self?.pointer.setPermissionGranted(granted)
            }

        pointer.onNativeButton = { [weak self] button in
            MainActor.assumeIsolated { self?.logitech.handleNativeButton(button) ?? false }
        }
        logitech.onAction = { action in
            if action.hasPrefix("app:") {
                MacroRunner.perform(.openApplication, applicationPath: String(action.dropFirst(4)))
            } else if let action = MacroAction(rawValue: action) { MacroRunner.perform(action) }
        }
        pointer.onPermissionRequest = { [weak self] in self?.permissions.requestAccessibility() }
        permissions.onRestart = { [weak self] in self?.restartForPermissions() }

        energy.onAutoStop = { [weak self] message in
            self?.showToast(message, symbol: "battery.25percent")
        }
        keyboard.onToast = { [weak self] message, symbol in
            self?.showToast(message, symbol: symbol)
        }
        keyboard.onRequestPermission = { [weak self] in self?.permissions.requestAccessibility() }
        batterySink = monitor.$battery
            .removeDuplicates()
            .sink { [weak self] battery in
                guard let battery else { return }
                Task { @MainActor in
                    self?.energy.enforceBattery(level: battery.level, pluggedIn: battery.isPluggedIn)
                }
            }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    var visibleModules: [AuroraModule] {
        settings.visibleModules
    }

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill") {
        toastSymbol = symbol
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { self.toast = nil }
        }
    }

    func select(_ module: AuroraModule) {
        withAnimation(.smooth(duration: 0.26)) { self.module = module }
        monitor.resume()
    }
}
