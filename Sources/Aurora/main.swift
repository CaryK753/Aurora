import AppKit
import LogitechPlugin
import SwiftUI

if CommandLine.arguments.contains("--logitech-diagnostics") || CommandLine.arguments.contains("--logitech-verify") {
    if CommandLine.arguments.contains("--logitech-verify"),
       NSRunningApplication.runningApplications(withBundleIdentifier: "com.cary.aurora").contains(where: { $0.processIdentifier != getpid() }) {
        print("请先退出正在运行的 Aurora，再执行硬件写入检查，避免两个进程争用鼠标。")
        exit(1)
    }
    let lines = LogitechDiagnostics.scan(verifyCurrentValues: CommandLine.arguments.contains("--logitech-verify"))
    print(lines.joined(separator: "\n"))
    exit(lines.contains(where: { $0.hasPrefix("error:") }) ? 1 : 0)
}

if CommandLine.arguments.contains("--permission-probe") {
    let data = try JSONEncoder().encode(PermissionSnapshot.capture())
    FileHandle.standardOutput.write(data)
    exit(0)
}

// Swift 包的 main 入口：以 accessory 模式常驻菜单栏
var auroraDelegate: AppDelegate?

if let index = CommandLine.arguments.firstIndex(of: "--update-script") {
    // 开发用：打印替换脚本，便于在临时目录里验证，不碰真实安装
    let args = CommandLine.arguments
    guard index + 3 < args.count else {
        print("用法：Aurora --update-script <target.app> <staged.app> <pid>")
        exit(1)
    }
    let pid = Int32(args[index + 3]) ?? 1
    let script = UpdateService.installScript(
        target: URL(fileURLWithPath: args[index + 1]),
        staged: URL(fileURLWithPath: args[index + 2]),
        pid: pid
    )
    print(script)
    exit(0)
}

if CommandLine.arguments.contains("--update-test") {
    final class Box: @unchecked Sendable {
        var done = false
        var text = ""
    }
    let box = Box()
    MainActor.assumeIsolated {
        let service = UpdateService()
        let deep = CommandLine.arguments.contains("--download")
        Task { @MainActor in
            box.text = deep ? await service.diagnoseWithDownload() : await service.diagnose()
            box.done = true
        }
    }
    while !box.done {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    print(box.text)
    exit(box.text.hasPrefix("失败") ? 1 : 0)
}

if CommandLine.arguments.contains("--toggle-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated {
        code = SelfTest.toggleRoundTrip()
    }
    exit(code)
}

if CommandLine.arguments.contains("--action-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.customActionRoundTrip() }
    exit(code)
}

if CommandLine.arguments.contains("--action-demo") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.createDemoAction() }
    exit(code)
}

if CommandLine.arguments.contains("--login-off") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.setLoginItem(false) }
    exit(code)
}

if CommandLine.arguments.contains("--login-on") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.setLoginItem(true) }
    exit(code)
}

if CommandLine.arguments.contains("--energy-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.energyRoundTrip() }
    exit(code)
}

if CommandLine.arguments.contains("--scroll-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.scrollTransform() }
    exit(code)
}

if let index = CommandLine.arguments.firstIndex(of: "--screen-render") {
    let args = CommandLine.arguments
    let pattern = index + 1 < args.count ? args[index + 1] : "white"
    let path = index + 2 < args.count ? args[index + 2] : "/tmp/aurora-pattern.png"
    var code: Int32 = 0
    MainActor.assumeIsolated {
        code = DevPreview.renderScreenPattern(pattern, to: path)
    }
    exit(code)
}

if let index = CommandLine.arguments.firstIndex(of: "--keytest-render") {
    let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "/tmp/aurora-keytest.png"
    var code: Int32 = 0
    MainActor.assumeIsolated { code = DevPreview.renderKeyTest(to: path) }
    exit(code)
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    let args = CommandLine.arguments
    let module = index + 1 < args.count ? args[index + 1] : "overview"
    let path = index + 2 < args.count ? args[index + 2] : "/tmp/aurora-render.png"
    let appearance = index + 3 < args.count ? args[index + 3] : "dark"
    let height = index + 4 < args.count ? (Double(args[index + 4]) ?? 0) : 0
    let width = index + 5 < args.count ? (Double(args[index + 5]) ?? 0) : 0
    var code: Int32 = 0
    MainActor.assumeIsolated {
        code = DevPreview.render(module: module, to: path, appearance: appearance, height: height, width: width)
    }
    exit(code)
}

if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let args = CommandLine.arguments
    let module = index + 1 < args.count ? args[index + 1] : "overview"
    let path = index + 2 < args.count ? args[index + 2] : "/tmp/aurora-snapshot.png"
    let appearance = index + 3 < args.count ? args[index + 3] : "dark"
    var code: Int32 = 0
    MainActor.assumeIsolated {
        code = WindowSnapshot.capture(module: module, to: path, appearance: appearance)
    }
    exit(code)
}

if CommandLine.arguments.contains("--audio-mute-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioMuteLeak() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-service-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioServiceRoundTrip() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-tap-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioTapRoundTrip() }
    exit(code)
}

if CommandLine.arguments.contains("--brand-icons") {
    MainActor.assumeIsolated {
        let content = HStack(spacing: 12) {
            ForEach(["opencode", "antigravity"], id: \.self) { id in
                Group {
                    if let image = BrandMarks.image(for: id, size: 96) {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 96, height: 96)
            }
        }
        .padding(16)
        .background(Color(white: 0.12))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/aurora-brand.png"))
            print("saved")
        } else {
            print("render failed")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--ai-scan") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.aiScan() }
    exit(code)
}

if CommandLine.arguments.contains("--ext-devices") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.externalDevices() }
    exit(code)
}

if CommandLine.arguments.contains("--clip-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.clipboardCompat() }
    exit(code)
}

if CommandLine.arguments.contains("--keyboard-clean-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.keyboardClean() }
    exit(code)
}

if CommandLine.arguments.contains("--welcome-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.welcomeFlow() }
    exit(code)
}

if CommandLine.arguments.contains("--clip-e2e") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.clipboardE2E() }
    exit(code)
}

if CommandLine.arguments.contains("--device-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.deviceScan() }
    exit(code)
}

if CommandLine.arguments.contains("--selftest") {
    var exitCode: Int32 = 0
    MainActor.assumeIsolated {
        exitCode = SelfTest.run()
    }
    print("")
    exit(exitCode)
}

MainActor.assumeIsolated {
    guard SingleInstance.acquire() else { exit(0) }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    auroraDelegate = delegate
    application.delegate = delegate
    application.run()
}
