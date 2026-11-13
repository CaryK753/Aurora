//  DevPreview.swift
//  Aurora — 离屏渲染：不依赖屏幕，直接把某个模块渲染成 PNG（用来核对布局/文案）
//
//  用法：Aurora --render <module> <output.png> [light|dark]
//  说明：ImageRenderer 不会绘制 NSGlassEffectView 与材质模糊，所以背景是纯色，
//        其余布局、字号、换行、裁切与真机一致。

import AppKit
import SwiftUI

/// 存储页要等扫描（du 统计目录体积）跑完再截图，否则只有骨架
@MainActor
func waitForStorageScan(_ state: AppState) {
    let deadline = Date().addingTimeInterval(40)
    while (state.storage.isScanning || state.storage.isFindingBigFiles) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
}

@MainActor
enum DevPreview {
    @ViewBuilder
    private static func moduleView(_ state: AppState) -> some View {
        switch state.module {
        case .overview: OverviewView(state: state)
        case .display: DisplayView(state: state)
        case .pointer: PointerView(state: state)
        case .trackpad: TrackpadView(service: state.trackpad)
        case .keyboard: KeyboardView(state: state)
        case .menu: ContextMenuView(state: state)
        case .desktop: DesktopView(state: state)
        case .clipboard: ClipboardView(state: state)
        case .screenshot: ScreenshotView(state: state)
        case .recorder: RecorderView(state: state)
        case .energy: EnergyView(state: state)
        case .audio: AudioView(state: state)
        case .storage: StorageView(state: state)
        case .ai: AIView(state: state)
        case .settings: SettingsView(state: state)
        }
    }

    /// 屏幕检测图案的离屏预览（只用于核对图案本身，不影响真实显示器）
    @ViewBuilder
    static func previewBody(_ state: AppState, module: String) -> some View {
        if module == "storage-apps" {
            StorageView(state: state, initialTab: .apps)
        } else if module == "storage-dev" {
            StorageView(state: state, initialTab: .dev)
        } else {
            moduleView(state)
        }
    }

    static func renderScreenPattern(_ raw: String, to path: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        guard let pattern = ScreenPattern(rawValue: raw) else {
            print("未知图案：\(raw)")
            return 1
        }
        let content = ScreenTestSurface(pattern: pattern)
            .frame(width: 480, height: 270)
            .clipped()
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("已输出：\(path)")
            return 0
        } catch {
            print("写入失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// 按键测试窗口的离屏预览
    static func renderKeyTest(to path: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let content = KeyTestView(monitor: KeyTestMonitor())
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? png.write(to: URL(fileURLWithPath: path))
        print("已输出：\(path)")
        return 0
    }

    static func render(module: String, to path: String, appearance: String, height: CGFloat = 0, width: CGFloat = 0) -> Int32 {
        // SwiftUI 的渲染需要 NSApplication 存在
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if appearance == "light" {
            app.appearance = NSAppearance(named: .aqua)
        } else if appearance == "dark" {
            app.appearance = NSAppearance(named: .darkAqua)
        }

        let state = AppState(preview: true)
        // 让采样跑起来，截图里才有真实数字
        RunLoop.main.run(until: Date().addingTimeInterval(2.8))
        if let target = AuroraModule(rawValue: module) {
            state.module = target
        }
        // 离屏渲染不会跑视图的 .task，扫描得手动起一次
        if module == "storage" || module == "storage-apps" || module == "storage-dev" {
            state.module = .storage
            state.storage.scan()
            waitForStorageScan(state)
            if module == "storage" {
                Task { await state.universal.scan() }
                waitUntil(timeout: 60) { state.universal.lastScan != nil && !state.universal.isScanning }
            }
            if module == "storage-apps" {
                Task { await state.appInventory.scan() }
                waitUntil(timeout: 90) { state.appInventory.lastScan != nil && !state.appInventory.isScanning }
            } else if module == "storage-dev" {
                Task { await state.devCleanup.scan() }
                waitUntil(timeout: 90) { state.devCleanup.lastScan != nil && !state.devCleanup.isFindingProjects }
            }
        }
        if appearance == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else if appearance == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // 罗技设置向导单独预览：--render logitech-setup2 渲染第 2 步
        if module.hasPrefix("logitech-setup") {
            let step = Int(module.dropFirst("logitech-setup".count)) ?? 0
            let setup = LogitechSetupView(state: state, initialStep: step)
                .environment(\.colorScheme, appearance == "light" ? .light : .dark)
            let renderer = ImageRenderer(content: setup)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("渲染失败")
                return 1
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("已输出：\(path) (660×600 @2x)")
                return 0
            } catch {
                print("写入失败：\(error.localizedDescription)")
                return 1
            }
        }

        let base = PanelController.panelSize
        let size = CGSize(width: width > 0 ? width : base.width, height: height > 0 ? height : base.height)
        // 直接用模块视图（不带 ScrollView），ImageRenderer 才能把它们完整排版出来
        let content = VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(T(state.module.title))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            previewBody(state, module: module)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            Spacer(minLength: 0)
        }
        .padding(.leading, 54)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(appearance == "light" ? Color(white: 0.97) : Color(white: 0.09))
        .environment(\.colorScheme, appearance == "light" ? .light : .dark)
        .environment(\.auroraContentWidth, size.width - 54 - 28)
        // 关掉动画，避免快照抓到过渡中的半透明状态
        .transaction { transaction in transaction.animation = nil }

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("已输出：\(path) (\(Int(size.width))×\(Int(size.height)) @2x)")
            return 0
        } catch {
            print("写入失败：\(error.localizedDescription)")
            return 1
        }
    }
}



// MARK: - 真窗口快照（不依赖屏幕录制权限）

@MainActor
enum WindowSnapshot {    /// 截图编辑器真窗口快照（检查工具栏在 13 个工具下是否溢出）
    static func captureEditor(to path: String, appearance: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = appearance == "light" ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)

        // 生成一张测试底图（渐变 + 网格，方便看标注位置）
        let size = CGSize(width: 1280, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        for x in stride(from: 0, to: size.width, by: 80) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 0))
            line.line(to: NSPoint(x: x, y: size.height))
            line.stroke()
        }
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }

        let window = EditorWindow(image: cg)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))

        guard let view = window.contentView?.superview else { return 1 }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return 1 }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("已输出：\(path)")
            window.orderOut(nil)
            return 0
        } catch {
            print("写入失败：\(error.localizedDescription)")
            return 1
        }
    }


    /// 罗技设置向导真窗口快照：GroupBox / Toggle 这类 AppKit 控件离屏渲染不出来，只能开真窗口
    static func captureSetup(step: Int, to path: String, appearance: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = appearance == "light" ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)

        let state = AppState(preview: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        let hosting = NSHostingView(rootView: LogitechSetupView(state: state, initialStep: step)
            .environment(\.colorScheme, appearance == "light" ? .light : .dark))
        window.contentView = hosting
        window.center()
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        // 窗口是自适应高度的，快照也要按内容的理想高度取景
        let fit = hosting.fittingSize
        if fit.height > 200 {
            window.setContentSize(NSSize(width: 660, height: fit.height))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let view = window.contentView?.superview else { return 1 }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return 1 }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("已输出：\(path)")
            window.orderOut(nil)
            return 0
        } catch {
            print("写入失败：\(error.localizedDescription)")
            return 1
        }
    }

    static func capture(module: String, to path: String, appearance: String) -> Int32 {        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = appearance == "light" ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)

        let state = AppState(preview: true)
        let pinned = ProcessInfo.processInfo.arguments.contains("--preview-pinned")
        state.setPinned(pinned)
        // SettingsService 初始化时会按偏好覆盖外观，这里以参数为准
        state.settings.appearance = appearance == "light" ? .light : .dark
        if let target = AuroraModule(rawValue: module) { state.module = target }
        // 开发调试：--preview-wallpaper 直接摆出壁纸覆盖页
        if ProcessInfo.processInfo.arguments.contains("--preview-wallpaper") {
            state.showWallpaper = true
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-import") { state.showImport = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if module == "storage" { waitForStorageScan(state) }

        let size = PanelController.panelSize
        let window = AuroraPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: pinned ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.allowsMain = pinned
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 26
        glass.style = .regular

        let hosting = TransparentHostingView(rootView: AuroraRootView(state: state))
        hosting.safeAreaRegions = []
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        window.contentView = glass
        window.orderFrontRegardless()

        RunLoop.main.run(until: Date().addingTimeInterval(0.9))

        guard let view = window.contentView?.superview else { return 1 }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("无法创建位图")
            return 1
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("已输出：\(path)")
            window.orderOut(nil)
            return 0
        } catch {
            print("写入失败：\(error.localizedDescription)")
            return 1
        }
    }
}
