//  DevPreview.swift
//  Aurora — 离屏渲染：不依赖屏幕，直接把某个模块渲染成 PNG（用来核对布局/文案）
//
//  用法：Aurora --render <module> <output.png> [light|dark]
//  说明：ImageRenderer 不会绘制 NSGlassEffectView 与材质模糊，所以背景是纯色，
//        其余布局、字号、换行、裁切与真机一致。

import AppKit
import SwiftUI

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
        case .energy: EnergyView(state: state)
        case .audio: AudioView(state: state)
        case .ai: AIView(state: state)
        case .settings: SettingsView(state: state)
        }
    }

    /// 屏幕检测图案的离屏预览（只用于核对图案本身，不影响真实显示器）
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

    static func render(module: String, to path: String, appearance: String, height: CGFloat = 0) -> Int32 {
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
        if appearance == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else if appearance == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let base = PanelController.panelSize
        let size = CGSize(width: base.width, height: height > 0 ? height : base.height)
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

            moduleView(state)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            Spacer(minLength: 0)
        }
        .padding(.leading, 54)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(appearance == "light" ? Color(white: 0.97) : Color(white: 0.09))
        .environment(\.colorScheme, appearance == "light" ? .light : .dark)
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
enum WindowSnapshot {
    static func capture(module: String, to path: String, appearance: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = appearance == "light" ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)

        let state = AppState(preview: true)
        // SettingsService 初始化时会按偏好覆盖外观，这里以参数为准
        state.settings.appearance = appearance == "light" ? .light : .dark
        if let target = AuroraModule(rawValue: module) { state.module = target }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let size = PanelController.panelSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 26
        glass.style = .regular

        let hosting = NSHostingView(rootView: AuroraRootView(state: state))
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        window.contentView = glass
        window.orderFrontRegardless()

        RunLoop.main.run(until: Date().addingTimeInterval(0.9))

        guard let view = window.contentView else { return 1 }
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
