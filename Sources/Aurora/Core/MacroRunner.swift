import AppKit
import CoreAudio

@MainActor
enum MacroRunner {
    static var dismissPanel: (() -> Void)?
    static var onError: ((String) -> Void)?
    static var toggleMute: (() -> Void)?
    private static var activationObserver: NSObjectProtocol?
    private static var lastExternalApp: NSRunningApplication?

    static func startObservingApplications() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { lastExternalApp = app }
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in if app.processIdentifier != getpid() { lastExternalApp = app } }
        }
    }

    static func perform(_ action: MacroAction, applicationPath: String? = nil) {
        guard action != .none else { return }
        Debug.log("macro action=\(action.rawValue)")
        switch action {
        case .none: return
        case .back, .forward:
            let current = NSWorkspace.shared.frontmostApplication
            guard let target = (current?.processIdentifier == getpid() ? lastExternalApp : current), !target.isTerminated else {
                fail("没有可接收前进或后退的应用"); return
            }
            dismissPanel?()
            target.activate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                    fail("无法切换到目标应用，请先激活该应用"); return
                }
                postKey(action == .back ? 0x21 : 0x1E, flags: .maskCommand, target: target.processIdentifier)
            }
        case .missionControl:
            dismissPanel?()
            open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .launchpad:
            dismissPanel?()
            let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            guard let path = apps.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                fail("系统中找不到 Apps 或启动台"); return
            }
            open(URL(fileURLWithPath: path))
        case .openApplication:
            guard let applicationPath, applicationPath.hasPrefix("/"), applicationPath.hasSuffix(".app"),
                  FileManager.default.fileExists(atPath: applicationPath) else {
                fail("请先为此按键选择应用程序"); return
            }
            dismissPanel?()
            open(URL(fileURLWithPath: applicationPath))
        case .screenshot:
            guard CGPreflightScreenCaptureAccess() else { fail("截图需要屏幕录制权限，请在设置中授权"); return }
            dismissPanel?()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-c"]
                do { try process.run() } catch { fail("无法启动截图工具") }
            }
        case .mute:
            toggleMute?()
        case .playPause:
            guard CGPreflightPostEventAccess() else { fail("播放控制需要辅助功能权限"); return }
            for down in [true, false] { MacroEvents.media(16, down: down)?.post(tap: .cghidEventTap) }
        case .showDesktopShortcut:
            dismissPanel?()
            guard let (code, flags) = DockActions.desktopShortcut() else { fail("请先在系统设置中启用显示桌面快捷键"); return }
            postKey(code, flags: flags)
        case .showDesktop:
            dismissPanel?()
            if !DockActions.showDesktop() {
                guard let (code, flags) = DockActions.desktopShortcut() else { fail("请先在系统设置中启用显示桌面快捷键"); return }
                postKey(code, flags: flags)
            }
        }
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags, target: pid_t? = nil) {
        guard CGPreflightPostEventAccess() else { fail("按键映射需要辅助功能权限"); return }
        for down in [true, false] {
            guard let event = MacroEvents.key(code, down: down, flags: flags) else { continue }
            event.post(tap: .cghidEventTap)
        }
    }

    private static func open(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in fail(error.localizedDescription) } }
        }
    }

    private static func fail(_ message: String) {
        Debug.log("macro failed: \(message)")
        onError?(T(message))
    }
}
