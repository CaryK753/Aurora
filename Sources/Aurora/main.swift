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

if CommandLine.arguments.contains("--editor-snapshot") {
    let args = CommandLine.arguments
    let index = args.firstIndex(of: "--editor-snapshot")!
    let path = index + 1 < args.count ? args[index + 1] : "/tmp/aurora-editor.png"
    let appearance = index + 2 < args.count ? args[index + 2] : "dark"
    var code: Int32 = 0
    MainActor.assumeIsolated { code = WindowSnapshot.captureEditor(to: path, appearance: appearance) }
    exit(code)
}

if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let args = CommandLine.arguments
    let module = index + 1 < args.count ? args[index + 1] : "overview"
    let path = index + 2 < args.count ? args[index + 2] : "/tmp/aurora-snapshot.png"
    let appearance = index + 3 < args.count ? args[index + 3] : "dark"
    var code: Int32 = 0
    // --snapshot logitech-setup2：罗技向导第 3 步的真窗口快照
    if module.hasPrefix("logitech-setup") {
        let step = Int(module.dropFirst("logitech-setup".count)) ?? 0
        MainActor.assumeIsolated { code = WindowSnapshot.captureSetup(step: step, to: path, appearance: appearance) }
        exit(code)
    }
    // --snapshot whatsnew：「新功能」窗口的真窗口快照
    if module == "whatsnew" {
        MainActor.assumeIsolated { code = WindowSnapshot.captureWhatsNew(to: path, appearance: appearance) }
        exit(code)
    }
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

if CommandLine.arguments.contains("--record-test") {
    let args = CommandLine.arguments
    let index = args.firstIndex(of: "--record-test")!
    let seconds = index + 1 < args.count ? (Double(args[index + 1]) ?? 6) : 6
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.recorderRoundTrip(seconds: seconds) }
    exit(code)
}

/// 画中画录制自测：开启摄像头气泡录一段，用来核对气泡是否真的被录进画面
if CommandLine.arguments.contains("--record-pip-test") {
    let args = CommandLine.arguments
    let index = args.firstIndex(of: "--record-pip-test")!
    let seconds = index + 1 < args.count ? (Double(args[index + 1]) ?? 4) : 4
    var code: Int32 = 0
    MainActor.assumeIsolated {
        // 覆盖层是 AppKit 窗口，没有启动好的 NSApplication 就不会真正上屏，
        // 那样录到的画面里自然也没有气泡
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        code = SelfTest.recorderRoundTrip(seconds: seconds, pip: true)
    }
    exit(code)
}

if CommandLine.arguments.contains("--canvas-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.canvasInteraction() }
    exit(code)
}

if CommandLine.arguments.contains("--display-link-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.displayBrightnessLink() }
    exit(code)
}

if CommandLine.arguments.contains("--app-uninstall-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.appUninstall() }
    exit(code)
}

// 插入点定位（AX）必须在 App 启动完成后才可用，先 finishLaunching 再查
if CommandLine.arguments.contains("--caret-e2e-test") || CommandLine.arguments.contains("--caret-probe") {
    let wantsE2E = CommandLine.arguments.contains("--caret-e2e-test")
    var code: Int32 = 0
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if wantsE2E {
            code = SelfTest.caretEndToEnd()
        } else {
            CaretLocator.diagnose().forEach { print($0) }
        }
    }
    exit(code)
}

if CommandLine.arguments.contains("--keystroke-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.keystrokeDisplay() }
    exit(code)
}

if CommandLine.arguments.contains("--mini-clipboard-position-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.miniClipboardPlacement() }
    exit(code)
}

if CommandLine.arguments.contains("--camera-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.cameraCheck() }
    exit(code)
}

if CommandLine.arguments.contains("--video-bezel-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.videoBezel() }
    exit(code)
}

if CommandLine.arguments.contains("--universal-thin-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.universalThin() }
    exit(code)
}

if CommandLine.arguments.contains("--storage-trash-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.storageTrash() }
    exit(code)
}

if CommandLine.arguments.contains("--storage-scan-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.storageScan() }
    exit(code)
}

if CommandLine.arguments.contains("--logitech-wizard-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.logitechWizard() }
    exit(code)
}

if CommandLine.arguments.contains("--import-scan") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.importScan() }
    exit(code)
}

if CommandLine.arguments.contains("--display-ddc-write-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.displayDDCWrite() }
    exit(code)
}

if CommandLine.arguments.contains("--display-ddc-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.displayDDCReport() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-service-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioServiceRoundTrip() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-default-app-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioDefaultInApp() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-default-listener-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioDefaultListener() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-default-chain-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioDefaultSwitchWithChain() }
    exit(code)
}

if CommandLine.arguments.contains("--audio-default-test") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SelfTest.audioDefaultSwitch() }
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

/// 外壳资源自检：确认打包后的 app 能从 Contents/Resources/DeviceFrames 里读到 PNG 与清单
if CommandLine.arguments.contains("--frames-report") {
    var code: Int32 = 0
    MainActor.assumeIsolated {
        let frames = ScreenshotService.shared.frames
        print("清单：\(ScreenshotService.resourceURL("frames.json")?.path ?? "未找到")")
        print("设备外壳 \(frames.count) 款")
        for frame in frames {
            print("  · \(frame.id) — \(frame.device) · \(Int(frame.pixelWidth))×\(Int(frame.pixelHeight))")
        }
        if frames.isEmpty { print("✗ 没读到最后壳资源，检查 Contents/Resources/DeviceFrames") }
        code = frames.isEmpty ? 1 : 0
    }
    exit(code)
}

/// 更新说明解析自检：打印当前版本的结构化说明，顺带跑一段截图里那种 HTML 的回归用例
if CommandLine.arguments.contains("--notes-report") {
    var dirty = false
    MainActor.assumeIsolated {
        let preview = ReleaseNotesStore.previewContent()
        print("CHANGELOG：\(ReleaseNotesStore.changelogURL()?.path ?? "未找到")")
        print("版本 \(preview.version) · 主题「\(preview.notes?.headline ?? "-")」· \(preview.notes?.sections.count ?? 0) 组 · \(preview.notes?.itemCount ?? 0) 条")
        for section in preview.notes?.sections ?? [] {
            print("\n[\(section.title.isEmpty ? "（无小标题）" : section.title)]")
            for item in section.items {
                print("  · \(item.title.isEmpty ? "（无小标题）" : item.title)")
                if !item.detail.isEmpty {
                    let detail = item.detail.replacingOccurrences(of: "\n", with: " ")
                    print("    \(detail.prefix(56))…")
                }
            }
        }

        let html = """
        <h2>Aurora v1.4.0</h2>
        <p><strong>存储、显示器与鼠标。</strong></p>
        <h3>新增</h3>
        <ul>
        <li><strong>罗技鼠标设置向导</strong>：检测到（疑似）罗技鼠标后发一条系统通知，并弹出向导。</li>
        <li><p><strong>插件长期启用</strong>：鼠标离线时卡片依旧在。</p><p>重新连上自动接管 &amp; 每只鼠标记住方案。</p></li>
        </ul>
        <h3>修复</h3>
        <ul><li>罗技插件在设备休眠 / 断连瞬间会被整块隐藏&#8212;现在不会了。</li></ul>
        """
        let parsed = ReleaseNotesParser.parse(html, version: "1.4.0")
        print("\nHTML 回归：主题「\(parsed.headline)」· 分组 \(parsed.sections.map(\.title)) · \(parsed.itemCount) 条")
        print("更新弹窗摘要：\(parsed.highlights())")
        dirty = parsed.allItems.contains {
            $0.detail.contains("<") || $0.detail.contains(">") || $0.title.contains("<")
        }
        print(dirty ? "✗ 仍有未处理的标签" : "✓ 没有残留标签")
    }
    exit(dirty ? 1 : 0)
}

/// 更新弹窗正文自检：用截图里那种 HTML 正文，确认弹窗里只剩干净的文案
if CommandLine.arguments.contains("--update-message") {
    let html = """
    <h2>Aurora v1.4.0</h2>
    <p><strong>存储、显示器与鼠标。</strong></p>
    <h3>新增</h3>
    <ul>
    <li><strong>罗技鼠标设置向导</strong>：检测到（疑似）罗技鼠标后发一条系统通知，并弹出向导。</li>
    <li><strong>插件长期启用</strong>：鼠标离线时卡片依旧在、开关保持开启。</li>
    <li><strong>按应用音量刻度</strong>：音量拖动条加上每 10% 一格的刻度。</li>
    <li><strong>显示器对齐 MonitorControl</strong>：DDC 按显示器真实量程换算。</li>
    <li><strong>多屏亮度联动</strong>：四档联动方式。</li>
    </ul>
    """
    let release = AuroraRelease(version: "1.4.0", tag: "v1.4.0", notes: html, publishedAt: nil,
                                asset: nil, assetName: nil, page: UpdateService.releasesPage)
    print(UpdateService.installSummary(release: release, currentVersion: "1.3.0", size: "42.1 MB"))
    exit(0)
}

/// 更新弹窗外观走查：用一段 HTML 正文把真实的 NSAlert 弹出来，只看样子
if CommandLine.arguments.contains("--update-alert-preview") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let html = """
        <h2>Aurora v1.4.0</h2>
        <p><strong>存储、显示器与鼠标。</strong></p>
        <h3>新增</h3>
        <ul>
        <li><strong>罗技鼠标设置向导</strong>：检测到（疑似）罗技鼠标后发一条系统通知，并弹出向导。</li>
        <li><strong>插件长期启用</strong>：鼠标离线时卡片依旧在、开关保持开启。</li>
        <li><strong>按应用音量刻度</strong>：音量拖动条加上每 10% 一格的刻度。</li>
        <li><strong>显示器对齐 MonitorControl</strong>：DDC 按显示器真实量程换算。</li>
        <li><strong>多屏亮度联动</strong>：四档联动方式。</li>
        </ul>
        """
        let release = AuroraRelease(version: "1.4.0", tag: "v1.4.0", notes: html, publishedAt: nil,
                                    asset: nil, assetName: nil, page: UpdateService.releasesPage)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = TF("发现新版本 %@", release.version)
        alert.informativeText = UpdateService.installSummary(release: release, currentVersion: "1.3.0", size: "42.1 MB")
        alert.addButton(withTitle: T("立即更新"))
        alert.addButton(withTitle: T("稍后"))
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
    exit(0)
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
