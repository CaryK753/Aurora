import AppKit

extension AppState {
    func restartForPermissions() {
        // 保留欢迎页的临时选择，让重启后继续当前步骤。
        UserDefaults.standard.set(showWelcome, forKey: "onboarding.reopenAfterRestart")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for i in $(seq 1 100); do kill -0 \"$1\" 2>/dev/null || break; sleep 0.1; done; kill -0 \"$1\" 2>/dev/null && exit 1; exec /usr/bin/open \"$2\"",
                             "aurora-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            showToast(T("重新启动失败，请退出后重新打开 Aurora"), symbol: "exclamationmark.triangle")
        }
    }
}
