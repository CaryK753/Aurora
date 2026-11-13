//  NotificationService.swift
//  Aurora — 系统通知（UserNotifications）
//
//  只用于「需要即时反馈」的场景，避免打扰：
//  · 发现新版本（自动下载完成，等你确认安装）
//  · 录屏完成 / 录制失败
//  · 截图保存到磁盘
//  · 屏保休息时间结束（节能）
//  未授权时全部静默跳过，绝不弹系统提示打扰。

import AppKit
import Combine
import UserNotifications

@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var authorized = false
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// 用户是否在设置里关掉了通知（默认开）
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notify.enabled")
        }
    }

    private var canUseSystemAPI: Bool { Bundle.main.bundleIdentifier != nil }

    private init() {
        enabled = UserDefaults.standard.object(forKey: "notify.enabled") as? Bool ?? true
        refresh()
    }

    func refresh() {
        guard canUseSystemAPI else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.status = settings.authorizationStatus
                self.authorized = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    /// 请求授权（设置页 / 权限页点按钮时调用）
    @discardableResult
    func request() async -> Bool {
        guard canUseSystemAPI else { return false }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        refresh()
        return granted
    }

    /// 发一条通知；未授权或用户关闭时静默跳过
    func post(title: String, body: String, sound: Bool = true, identifier: String = UUID().uuidString) {
        guard canUseSystemAPI, enabled else { return }
        guard authorized || status == .notDetermined else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 常用场景

    func notifyUpdateReady(version: String, currentVersion: String) {
        post(
            title: TN("Aurora 有新版本"),
            body: TF("v%@ 已下载完成，当前 v%@。打开 Aurora 确认后即可安装。", version, currentVersion)
        )
    }

    func notifyRecordingSaved(name: String) {
        post(title: TN("录屏已保存"), body: TF("%@ 已保存到「影片 › Aurora Recordings」。", name))
    }

    func notifyRecordingFailed(reason: String) {
        post(title: TN("录制失败"), body: reason)
    }

    func notifyScreenshotSaved(name: String) {
        post(title: TN("截图已保存"), body: name)
    }

    func notifyEnergyFinished() {
        post(title: TN("休息时间结束"), body: TN("Aurora 已恢复正常休眠策略。"))
    }

    /// 首次发现罗技鼠标：提示可以打开设置向导
    func notifyLogitechDetected(name: String) {
        post(
            title: TN("发现罗技鼠标"),
            body: TF("%@ 已连接，跟着向导完成鼠标设置。", name),
            identifier: "aurora.logitech.setup"
        )
    }
}

/// 通知文案走 T()，但标题需要短，单独包一层方便以后统一替换
@MainActor
func TN(_ key: String) -> String { T(key) }
