import AppKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--script" {
    print(UpdateInstaller.script(bundleID: CommandLine.arguments[2]))
    exit(0)
}

// 用独立 bundle ID 的小型菜单栏进程验证 LaunchServices 和安装回执。
@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    private let folder = Bundle.main.bundleURL.deletingLastPathComponent()
    private var window: NSPanel?
    private var attempts = 0
    private lazy var termination: ApplicationTermination = ApplicationTermination(prepare: { [unowned self] in
        attempts += 1
        window?.orderOut(nil)
        // 让一次界面回调穿过模拟的硬件清理，确认主线程没被阻塞。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [self] in
            if !window!.isVisible { try! Data().write(to: folder.appendingPathComponent("responsive")) }
        }
        try await Task.sleep(for: .milliseconds(180))
        if attempts == 1 && CommandLine.arguments.contains("--quit-retry") {
            throw CocoaError(.userCancelled)
        }
        try! Data().write(to: folder.appendingPathComponent("approved"))
    }, reportError: { [unowned self] _ in
        window?.orderFront(nil)
        try! Data().write(to: folder.appendingPathComponent("restored"))
        DispatchQueue.main.async { self.pressQuit() }
    })

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.systemRequest()
    }

    @objc private func pressQuit() { termination.begin() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--quit-") }) {
            let panel = NSPanel(contentRect: NSRect(x: 10, y: 10, width: 140, height: 50),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            window = panel
            let button = NSButton(title: "退出", target: self, action: #selector(pressQuit))
            panel.contentView = button
            panel.orderFront(nil)
            if CommandLine.arguments.contains("--quit-system") {
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in NSApp.terminate(nil) }
            } else {
                DispatchQueue.main.async { button.performClick(nil) }
            }
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        if version == "3.0" { exit(1) }
        if version == "2.1", !FileManager.default.fileExists(atPath: folder.appendingPathComponent("attempted").path) {
            try! Data().write(to: folder.appendingPathComponent("attempted"))
            exit(1)
        }
        try! String(getpid()).write(to: folder.appendingPathComponent("started-" + version),
                                    atomically: true, encoding: .utf8)
        UpdateInstaller.acknowledgeLaunch()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path) { exit(0) }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let fixture = Fixture()
    app.delegate = fixture
    app.setActivationPolicy(.accessory)
    app.run()
}
