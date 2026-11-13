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
    /// 更新后首次启动的「新功能」窗口
    @Published var showWhatsNew = false
    /// 全局快捷键页（与设置页同层的单层内容页，不是覆盖层）
    @Published var showHotkeys = false
    /// 罗技鼠标设置向导（检测到设备后自动弹出）
    @Published var showLogitechSetup = false
    /// 「动态壁纸」全屏覆盖层
    @Published var showWallpaper = false
    /// 固定窗口进入 macOS 全屏时为 true（圆角与红绿灯布局要跟着变）
    @Published var isFullscreen = false
    var onShowMainPanel: (() -> Void)?
    var onDismissMainPanel: (() -> Void)?

    // MARK: - 窗口固定

    /// 固定后主面板不再是弹出式临时窗口，而是正经的 macOS 窗口（原生红绿灯）
    @Published private(set) var isPinned = false
    /// 由 PanelController 接管真正的窗口形态切换
    var onSetPinned: ((Bool) -> Void)?
    /// 捕获按键时临时固定，结束后恢复成原样
    private var pinnedByCapture = false

    func setPinned(_ pinned: Bool) {
        guard isPinned != pinned else { return }
        isPinned = pinned
        onSetPinned?(pinned)
    }

    func togglePinned() {
        guard !pointer.isCapturing else { return }
        setPinned(!isPinned)
    }

    /// 像 Mos 那样先单独捕获按键、再指定动作；捕获期间窗口保持固定，
    /// 免得按到 ⌥⌘A 之类的快捷键把面板收起来
    func beginButtonCapture() {
        guard !pointer.isCapturing else { return }
        guard pointer.beginCapture() else {
            showToast(T("无法捕获按键，请先授予辅助功能权限"), symbol: "exclamationmark.triangle")
            return
        }
        if !isPinned {
            pinnedByCapture = true
            setPinned(true)
        }
    }

    func endButtonCapture() {
        let wasCapturing = pointer.isCapturing
        pointer.cancelCapture()
        releaseCapturePin()
        if wasCapturing { showToast(T("已取消捕获"), symbol: "xmark.circle") }
    }

    private func releaseCapturePin() {
        guard pinnedByCapture else { return }
        pinnedByCapture = false
        setPinned(false)
    }

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

    /// 打开「新功能」窗口（关于页 / 更新完成后都可）
    func openWhatsNew() {
        onDismissMainPanel?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.showWhatsNew = true
        }
    }

    func dismissMainPanel() {
        onDismissMainPanel?()
    }

    // MARK: - 罗技鼠标向导

    /// 设置向导当前对应的设备
    var logitechSetupDevice: LogitechKnownDevice? {
        logitech.pendingSetup ?? logitech.knownDevice(for: logitech.selectedID)
    }

    private func handleLogitechDetection(_ device: LogitechKnownDevice) {
        guard !showWelcome, !showLogitechSetup,
              UserDefaults.standard.bool(forKey: "onboarding.completed") else { return }
        NotificationService.shared.notifyLogitechDetected(name: device.name)
        showLogitechSetup = true
    }

    /// 用户从鼠标页手动打开向导（已提示过的设备也能重新配置）
    func openLogitechSetup() {
        showLogitechSetup = true
        if logitech.pendingSetup == nil { logitech.requestSetup() }
    }

    func dismissLogitechSetup() {
        showLogitechSetup = false
        logitech.dismissSetup()
    }

    // MARK: - 动态壁纸

    /// 全屏预览一张壁纸（Esc / 点击退出）
    func previewWallpaper(_ item: WallpaperItem, fill: WallpaperFill) {
        WallpaperPreview.present(item: item, fill: fill)
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
    let storage = StorageService()
    let appInventory = AppInventoryService()
    let devCleanup = DevCleanupService()
    let universal = UniversalService()
    let appAudio = PerAppAudioService()
    let ai = AIUsageService()
    let finderExt = FinderExtensionService()
    let hotkeys = HotkeyService()
    let updates = UpdateService()
    let settings: SettingsService
    let wallpapers: WallpaperLibrary
    let wallpaper: WallpaperService
    let permissions = PermissionService()

    private var toastTask: Task<Void, Never>?
    private var languageObserver: NSObjectProtocol?
    private var batterySink: AnyCancellable?
    private var permissionSink: AnyCancellable?
    private var hardwareSink: AnyCancellable?
    private var moduleSink: AnyCancellable?
    private var settingsSink: AnyCancellable?
    private var logitechSink: AnyCancellable?
    private var welcomeSink: AnyCancellable?

    /// preview=true：离屏渲染/快照用，外观等偏好只存在内存里，不污染真实设置
    init(preview: Bool = false) {
        settings = SettingsService(persistPreferences: !preview)
        wallpapers = WallpaperLibrary(scanSystem: !preview)
        wallpaper = WallpaperService(library: wallpapers)
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
                self?.display.refreshNativeKeys(accessibility: granted)
            }

        pointer.onNativeButton = { [weak self] button in
            MainActor.assumeIsolated { self?.logitech.handleNativeButton(button) ?? false }
        }
        // 检测到（疑似）罗技鼠标：发一条通知，并弹出设置向导。同一只鼠标只提示一次。
        logitechSink = logitech.$pendingSetup
            .compactMap { $0 }
            .sink { [weak self] device in
                Task { @MainActor in self?.handleLogitechDetection(device) }
            }
        // 欢迎页还在的时候先不打扰，等它收起来再补上向导
        welcomeSink = $showWelcome
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] visible in
                guard let self, !visible else { return }
                Task { @MainActor in
                    guard let pending = self.logitech.pendingSetup else { return }
                    self.handleLogitechDetection(pending)
                }
            }
        logitech.onAction = { action in
            if action.hasPrefix("app:") {
                MacroRunner.perform(.openApplication, applicationPath: String(action.dropFirst(4)))
            } else if let action = MacroAction(rawValue: action) { MacroRunner.perform(action) }
        }
        pointer.onPermissionRequest = { [weak self] in self?.permissions.requestAccessibility() }
        permissions.onRestart = { [weak self] in self?.restartForPermissions() }
        pointer.onCaptureFinished = { [weak self] button in
            guard let self else { return }
            self.releaseCapturePin()
            self.showToast(TF("已捕获 按键 %d", button), symbol: "computermouse.fill")
        }

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
        withAnimation(.smooth(duration: 0.26)) {
            self.module = module
            self.showHotkeys = false
        }
        monitor.resume()
    }
}
