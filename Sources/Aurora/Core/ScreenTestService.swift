//  ScreenTestService.swift
//  Aurora — 屏幕检测：全屏铺满所有显示器，纯色 / 灰阶 / 渐变 / 彩条 / 棋盘 / 网格 / 文本 / 坏点
//
//  ESC 退出，← → 或空格切换项目；HUD 3 秒后自动淡出，鼠标一动就回来。

import AppKit
import Combine
import SwiftUI

enum ScreenPattern: String, CaseIterable, Identifiable {
    case white, gray, black, red, green, blue
    case graySteps, gradient, colorBars, checker, grid, text, pixel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return T("纯白")
        case .gray: return T("中灰")
        case .black: return T("纯黑")
        case .red: return T("红")
        case .green: return T("绿")
        case .blue: return T("蓝")
        case .graySteps: return T("灰阶")
        case .gradient: return T("渐变")
        case .colorBars: return T("彩条")
        case .checker: return T("棋盘")
        case .grid: return T("网格")
        case .text: return T("文本")
        case .pixel: return T("坏点")
        }
    }

    var hint: String {
        switch self {
        case .white: return T("看亮度均匀度与暗角")
        case .gray: return T("看漏光、色偏与阴阳屏")
        case .black: return T("看亮点、坏点与黑位")
        case .red, .green, .blue: return T("看单色纯度与彩点")
        case .graySteps: return T("看灰阶过渡是否并阶")
        case .gradient: return T("看色带断层（banding）")
        case .colorBars: return T("看色彩饱和度与色温")
        case .checker: return T("看像素对齐与摩尔纹")
        case .grid: return T("看几何畸变与过扫描")
        case .text: return T("看文字锐度与次像素渲染")
        case .pixel: return T("白点移动，找出卡死像素")
        }
    }

    var swatch: Color? {
        switch self {
        case .white: return Color(white: 1)
        case .gray: return Color(white: 0.5)
        case .black: return Color(white: 0)
        case .red: return Color(red: 1, green: 0, blue: 0)
        case .green: return Color(red: 0, green: 0.9, blue: 0.2)
        case .blue: return Color(red: 0, green: 0.35, blue: 1)
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .white, .gray, .black: return "square.fill"
        case .red, .green, .blue: return "paintpalette.fill"
        case .graySteps: return "square.stack.3d.down.right.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .colorBars: return "rectangle.split.3x1.fill"
        case .checker: return "square.grid.3x3.fill"
        case .grid: return "grid"
        case .text: return "text.alignleft"
        case .pixel: return "scope"
        }
    }
}

/// 无边框窗口默认不能成为 key window，ESC 就收不到，这里显式打开
final class ScreenTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ScreenTestSession: ObservableObject {
    @Published var pattern: ScreenPattern = .white
    @Published var hudVisible = true

    var index: Int { ScreenPattern.allCases.firstIndex(of: pattern) ?? 0 }
    var total: Int { ScreenPattern.allCases.count }

    func step(_ delta: Int) {
        let all = ScreenPattern.allCases
        let next = (index + delta + all.count) % all.count
        pattern = all[next]
    }
}

@MainActor
final class ScreenTestService {
    static let shared = ScreenTestService()

    let session = ScreenTestSession()
    private(set) var isRunning = false
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var hideTask: Task<Void, Never>?

    /// target 为 nil 时铺满所有显示器，方便对比不同屏幕
    func start(pattern: ScreenPattern = .white, target: CGDirectDisplayID? = nil) {
        stop()
        session.pattern = pattern
        session.hudVisible = true

        let screens: [NSScreen]
        if let target,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target
           }) {
            screens = [screen]
        } else {
            screens = NSScreen.screens
        }
        guard !screens.isEmpty else { return }

        for screen in screens {
            let window = ScreenTestWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.contentView = NSHostingView(rootView: ScreenTestOverlay(
                session: session,
                screenName: screen.localizedName
            ))
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }

        isRunning = true
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        installMonitors()
        scheduleHUDHide()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        hideTask?.cancel()
        hideTask = nil
        removeMonitors()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    func revealHUD() {
        if !session.hudVisible {
            withAnimation(.easeOut(duration: 0.18)) { session.hudVisible = true }
        }
        scheduleHUDHide()
    }

    private func scheduleHUDHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, isRunning else { return }
            withAnimation(.easeInOut(duration: 0.35)) { session.hudVisible = false }
        }
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // esc
                stop()
                return nil
            case 123: // ←
                session.step(-1)
                revealHUD()
                return nil
            case 124: // →
                session.step(1)
                revealHUD()
                return nil
            case 49: // space
                session.step(1)
                revealHUD()
                return nil
            default:
                return event
            }
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .rightMouseDown {
                stop()
                return nil
            }
            revealHUD()
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }
}

// MARK: - 全屏内容

private struct ScreenTestOverlay: View {
    @ObservedObject var session: ScreenTestSession
    var screenName: String

    var body: some View {
        ZStack {
            ScreenTestSurface(pattern: session.pattern)

            VStack {
                Spacer()
                if session.hudVisible {
                    hud
                        .padding(.bottom, 42)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // 顶部与底部各留一条很窄的黑边，方便判断是否过扫描
            VStack {
                Rectangle().fill(Color.black.opacity(0.001)).frame(height: 1)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
    }

    private var hud: some View {
        HStack(spacing: 10) {
            Button { session.step(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())

            VStack(alignment: .leading, spacing: 1) {
                Text(TF("%@ · %d/%d", T(session.pattern.title), session.index + 1, session.total))
                    .font(.system(size: 11, weight: .semibold))
                Text(T(session.pattern.hint))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 132, alignment: .leading)

            Button { session.step(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())

            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.6, height: 22)

            HStack(spacing: 4) {
                Image(systemName: "display")
                    .font(.system(size: 8))
                Text(screenName)
                    .lineLimit(1)
            }
            .font(.system(size: 8.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 120, alignment: .leading)

            Button {
                // 按钮所在的窗口会被 stop() 释放，推到下一个 runloop 再关
                DispatchQueue.main.async { ScreenTestService.shared.stop() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                    Text("ESC")
                        .font(.system(size: 8.5, weight: .semibold))
                }
            }
            .buttonStyle(HUDButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }
}

private struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct ScreenTestSurface: View {
    let pattern: ScreenPattern

    var body: some View {
        GeometryReader { proxy in
            switch pattern {
            case .white: Color.white
            case .gray: Color(white: 0.5)
            case .black: Color.black
            case .red: Color(red: 1, green: 0, blue: 0)
            case .green: Color(red: 0, green: 1, blue: 0)
            case .blue: Color(red: 0, green: 0, blue: 1)
            case .graySteps:
                Canvas { context, size in
                    let steps = 21
                    for index in 0..<steps {
                        let value = Double(index) / Double(steps - 1)
                        let width = size.width / CGFloat(steps)
                        let rect = CGRect(
                            x: width * CGFloat(index),
                            y: 0,
                            width: width + 1,
                            height: size.height
                        )
                        context.fill(Path(rect), with: .color(Color(white: value)))
                    }
                }
            case .gradient:
                LinearGradient(
                    stops: (0...12).map { step in
                        Gradient.Stop(color: Color(white: Double(step) / 12), location: Double(step) / 12)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
            case .colorBars:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, color in
                            color
                        }
                    }
                    .frame(height: proxy.size.height * 0.76)

                    LinearGradient(
                        colors: [.black, .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: proxy.size.height * 0.16)

                    HStack(spacing: 0) {
                        ForEach(Array(Self.grayBars.enumerated()), id: \.offset) { _, color in
                            color
                        }
                    }
                }
            case .checker:
                Canvas { context, size in
                    let unit: CGFloat = 12
                    let columns = Int(ceil(size.width / unit))
                    let rows = Int(ceil(size.height / unit))
                    for column in 0...columns {
                        for row in 0...rows {
                            guard (column + row) % 2 == 0 else { continue }
                            context.fill(
                                Path(CGRect(x: CGFloat(column) * unit, y: CGFloat(row) * unit, width: unit, height: unit)),
                                with: .color(.white)
                            )
                        }
                    }
                }
                .background(Color.black)
            case .grid:
                ZStack {
                    Color.black
                    Canvas { context, size in
                        let step: CGFloat = 48
                        var path = Path()
                        var x: CGFloat = 0
                        while x <= size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                            x += step
                        }
                        var y: CGFloat = 0
                        while y <= size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            y += step
                        }
                        context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)

                        // 中心十字与四角标记：判断是否有过扫描/偏移
                        var cross = Path()
                        cross.move(to: CGPoint(x: size.width / 2 - 40, y: size.height / 2))
                        cross.addLine(to: CGPoint(x: size.width / 2 + 40, y: size.height / 2))
                        cross.move(to: CGPoint(x: size.width / 2, y: size.height / 2 - 40))
                        cross.addLine(to: CGPoint(x: size.width / 2, y: size.height / 2 + 40))
                        context.stroke(cross, with: .color(.red), lineWidth: 2)

                        let inset: CGFloat = 14
                        for corner in [
                            CGPoint(x: inset, y: inset),
                            CGPoint(x: size.width - inset, y: inset),
                            CGPoint(x: inset, y: size.height - inset),
                            CGPoint(x: size.width - inset, y: size.height - inset)
                        ] {
                            context.fill(
                                Path(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)),
                                with: .color(.red)
                            )
                        }
                    }
                }
            case .text:
                ZStack {
                    Color.black
                    VStack(alignment: .leading, spacing: 18) {
                        Text("HHHH iiii 8080 1lI O0")
                            .font(.system(size: proxy.size.height * 0.055, weight: .semibold))
                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(.system(size: proxy.size.height * 0.028, weight: .regular))
                        Text("屏幕锐度测试 · 细线 · 灰阶 · 小字 0123456789")
                            .font(.system(size: proxy.size.height * 0.016, weight: .regular))
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { index in
                                Rectangle()
                                    .fill(Color.white.opacity(index % 2 == 0 ? 0.9 : 0.25))
                                    .frame(width: 2, height: 36)
                            }
                        }
                        Text("1px 线条：应当清晰、没有彩色描边")
                            .font(.system(size: proxy.size.height * 0.012))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .padding(proxy.size.height * 0.08)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            case .pixel:
                TimelineView(.animation(minimumInterval: 0.09)) { timeline in
                    let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.09)
                    let columns = 12
                    let rows = 8
                    let index = tick % (columns * rows)
                    let column = index % columns
                    let row = index / columns
                    GeometryReader { geo in
                        let cellW = geo.size.width / CGFloat(columns)
                        let cellH = geo.size.height / CGFloat(rows)
                        ZStack(alignment: .topLeading) {
                            Color.black
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: min(cellW, cellH) * 0.24, height: min(cellW, cellH) * 0.24)
                                .position(
                                    x: cellW * (CGFloat(column) + 0.5),
                                    y: cellH * (CGFloat(row) + 0.5)
                                )
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private static let bars: [Color] = [
        .white, .yellow, .cyan, .green, Color(red: 1, green: 0, blue: 1), .red, .blue
    ]

    private static let grayBars: [Color] = [
        Color(white: 0.0), Color(white: 0.1), Color(white: 0.2), Color(white: 0.3),
        Color(white: 0.4), Color(white: 0.5), Color(white: 0.6), Color(white: 0.7),
        Color(white: 0.8), Color(white: 0.9), Color(white: 1.0)
    ]
}
