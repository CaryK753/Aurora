import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import UserNotifications

@MainActor
final class PermissionService: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let state: PermissionStatus
        let pane: String
        let prompt: (() -> Void)?
    }

    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var fullDiskAccess = false
    /// 通知授权（更新、录制完成等即时提醒）
    @Published private(set) var notifications = false
    @Published private(set) var lastCheck = Date.distantPast
    @Published private(set) var isChecking = false
    @Published private(set) var checkError: String?
    @Published private(set) var statuses: [String: PermissionStatus] = [:]
    var onRestart: (() -> Void)?
    private var fresh: PermissionSnapshot?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var fastPollTask: Task<Void, Never>?
    private var ticks = 0

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.ticks += 1
                if self.ticks % 10 == 0 { self.recheck() }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.recheck() } }
    }

    deinit {
        timer?.invalidate()
        fastPollTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func refresh(fullDisk: Bool = true) {
        let current = PermissionSnapshot.capture()
        statuses["accessibility"] = .resolve(current: current.accessibility, fresh: fresh?.accessibility)
        statuses["screen"] = .resolve(current: current.screenRecording, fresh: fresh?.screenRecording)
        statuses["input"] = .resolve(current: current.inputMonitoring, fresh: fresh?.inputMonitoring)
        if fullDisk {
            if fresh?.disk == .granted && current.disk == .denied { statuses["disk"] = .restartRequired }
            else {
                switch fresh?.disk ?? current.disk {
                case .granted: statuses["disk"] = .granted
                case .denied: statuses["disk"] = .denied
                case .unknown: statuses["disk"] = .unknown
                }
            }
        }
        accessibility = statuses["accessibility"] == .granted
        screenRecording = statuses["screen"] == .granted
        inputMonitoring = statuses["input"] == .granted
        fullDiskAccess = statuses["disk"] == .granted
        // 通知状态由 NotificationService 缓存，这里只读，避免每 3 秒打一次 UN 接口
        let notify = NotificationService.shared
        notifications = notify.authorized
        switch notify.status {
        case .authorized, .provisional, .ephemeral: statuses["notifications"] = .granted
        case .denied: statuses["notifications"] = .denied
        default: statuses["notifications"] = .unknown
        }
        lastCheck = Date()
    }

    /// 仅运行同一应用包内签名相同的只读探针，避开当前进程的授权缓存。
    func recheck() {
        refresh()
        guard !isChecking, Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL else { return }
        isChecking = true
        checkError = nil
        Task { [weak self] in
            let result = await PermissionProbe.run(executable: executable)
            guard let self else { return }
            self.isChecking = false
            switch result {
            case .success(let snapshot): self.fresh = snapshot
            case .failure(let error): self.checkError = error.localizedDescription
            }
            self.refresh()
            Debug.log("permission probe ax=\(String(describing: self.fresh?.accessibilityAPI)) post=\(String(describing: self.fresh?.eventPosting)) operation=\(String(describing: self.fresh?.accessibilityOperation))")
            Debug.log("permissions path=\(Bundle.main.bundlePath) states=\(self.statuses)")
        }
    }

    var items: [Item] {
        [
            Item(id: "accessibility", title: T("辅助功能"), subtitle: T("鼠标调校、侧键动作与粘贴"), symbol: "accessibility",
                 state: statuses["accessibility"] ?? .unknown, pane: "Privacy_Accessibility",
                 prompt: { [weak self] in self?.requestAccessibility() }),
            Item(id: "screen", title: T("屏幕录制"), subtitle: T("截图与录屏共用，可稍后授权"), symbol: "rectangle.dashed.badge.record",
                 state: statuses["screen"] ?? .unknown, pane: "Privacy_ScreenCapture",
                 prompt: { [weak self] in self?.requestScreenRecording() }),
            Item(id: "input", title: T("输入监控"), subtitle: T("读取原始设备事件，可选"), symbol: "keyboard",
                 state: statuses["input"] ?? .unknown, pane: "Privacy_ListenEvent",
                 prompt: { [weak self] in self?.requestInputMonitoring() }),
            Item(id: "notifications", title: T("通知"), subtitle: T("新版本、录制完成等即时提醒，可稍后授权"), symbol: "bell.badge",
                 state: statuses["notifications"] ?? .unknown, pane: "Notifications",
                 prompt: { [weak self] in self?.requestNotifications() }),
            Item(id: "disk", title: T("完全磁盘访问"), subtitle: T("读取受保护的本地用量或配置，可选"), symbol: "externaldrive.badge.checkmark",
                 state: statuses["disk"] ?? .unknown, pane: "Privacy_AllFiles", prompt: nil)
        ]
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPane("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPane("Privacy_ScreenCapture")
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openPane("Privacy_ListenEvent")
    }

    func requestNotifications() {
        Task { [weak self] in
            let granted = await NotificationService.shared.request()
            guard let self else { return }
            NotificationService.shared.refresh()
            self.refresh()
            if !granted { self.openPane("Notifications") }
        }
    }

    func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
        fastPollTask?.cancel()
        fastPollTask = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self else { return }
                self.recheck()
            }
        }
    }

    func openServiceManagement() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
