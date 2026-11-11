//  RootView.swift
//  Aurora — 主界面：左侧图标导航 + 顶部软边缘内容区

import SwiftUI

struct AuroraRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var monitor: SystemMonitor
    /// 捕获状态在 PointerService 上，必须单独订阅，否则提示条不会出现
    @ObservedObject private var pointer: PointerService
    @State private var appeared = false
    @Environment(\.colorScheme) private var scheme
    /// 内容是否已经滚到标题栏下面：只有这时才铺模糊层，静止时保持通透
    @State private var scrolledUnderHeader = true
    // ⌘ + 拖动侧边栏排序；拖出窗口松手停用模块（窗口级事件监听，可拖到屏幕任意位置）
    @State private var railFrames: [String: CGRect] = [:]
    @State private var draggingModule: AuroraModule?
    @State private var dragCoordinator = RailDragCoordinator()
    @State private var dragDownMonitor: Any?
    /// 捕获按键时呼吸的小圆点
    @State private var capturePulse = false
    /// 快捷键页走 state.showHotkeys（与设置页同层的单层内容页）
    /// 主内容区宽度：传给各模块做自适应排版
    @State private var contentWidth: CGFloat = PanelController.panelSize.width - 54 - 28

    init(state: AppState) {
        self.state = state
        self.monitor = state.monitor
        self.pointer = state.pointer
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                rail
                ZStack(alignment: .top) {
                    content
                    header
                }
            }

            if state.showImport {
                ImportView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                // 材质模糊在玻璃窗口上不可靠，垫一层主题色底保证可读；
                                // 迁移页卡片稀疏、内容又不多，底色要接近不透明
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .fill(scheme == .light ? Color.white.opacity(0.95) : Color.black.opacity(0.92))
                            }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }

            if state.showWallpaper {
                WallpaperView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                // 材质的模糊在部分场合不可靠，垫一层暗底保证可读
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .fill(scheme == .light ? Color.white.opacity(0.66) : Color.black.opacity(0.88))
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2.5)
            }

            VStack(spacing: 8) {
                if let toast = state.toast {
                    toastView(toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if pointer.isCapturing {
                    captureHUD
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 18)
            .zIndex(3)
        }
        .frame(
            minWidth: PanelController.panelSize.width,
            idealWidth: PanelController.panelSize.width,
            maxWidth: .infinity,
            minHeight: PanelController.panelSize.height,
            idealHeight: PanelController.panelSize.height,
            maxHeight: .infinity
        )
        .ignoresSafeArea(.container, edges: .top)
        // 浅色下给玻璃一层很淡的白色洗底：仍是半透明，但文字对比度够用
        .background(scheme == .light ? Color.white.opacity(0.45) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            dragCoordinator.hitModule = { point in
                let railPoint = railPoint(from: point)
                // 只接管落在侧栏 54pt 宽度内的按下，别误伤内容区的 ⌘ + 点击
                guard railPoint.x >= 0, railPoint.x <= 60 else { return nil }
                guard let index = dropIndex(at: railPoint) else { return nil }
                let middle = state.visibleModules.filter(\.isToggleable)
                return middle[safe: index]
            }
            dragCoordinator.onMove = { module, point in handleDragMove(module, to: point) }
            dragCoordinator.onEnd = { module, point in handleDragEnd(module, at: point) }
            if dragDownMonitor == nil {
                // ⌘ + 按下侧栏图标 → 接管为拖动排序；其余点击原样放行
                dragDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    if dragCoordinator.mouseDown(at: NSEvent.mouseLocation) { return nil }
                    return event
                }
            }
            Debug.log("root appeared")
            // 调试钩子：AURORA_SHOW_HOTKEYS=1 时直接打开快捷键页（供快照预览）
            if ProcessInfo.processInfo.environment["AURORA_SHOW_HOTKEYS"] == "1" {
                state.showHotkeys = true
            }
            withAnimation(.smooth(duration: 0.25)) { appeared = true }
        }
    }

    // MARK: - 导航

    /// 固定成普通窗口时用系统窗口的圆角，浮动面板则保持大圆角玻璃卡片；全屏交给系统，归零
    private var cornerRadius: CGFloat {
        if state.isFullscreen { return 0 }
        return state.isPinned ? PanelController.pinnedCornerRadius : PanelController.floatingCornerRadius
    }

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(state.visibleModules) { module in
                if module.startsGroup {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 20, height: 1)
                        .padding(.vertical, 4)
                }
                // 设置按钮上方放一个快捷键入口
                if module == .settings {
                    hotkeyRailButton
                        .padding(.bottom, 2)
                }
                railButton(module)
                    .opacity(draggingModule == module ? 0.32 : 1)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RailFrameKey.self,
                                value: [module.rawValue: proxy.frame(in: .named("auroraRail"))]
                            )
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        // 全屏时顶部有红绿灯 + Aurora 图标，导航按钮要再往下让
        .padding(.top, state.isFullscreen ? 94 : (state.isPinned ? 58 : 50))
        .padding(.bottom, 14)
        .frame(width: 54)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(name: "auroraRail")
        .onPreferenceChange(RailFrameKey.self) { railFrames = $0 }
        .background(alignment: .trailing) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.primary.opacity(0.065), location: 0.22),
                    .init(color: Color.primary.opacity(0.065), location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 0.7)
        }
        .overlay(alignment: .top) {
            // 固定后这里交给系统红绿灯；全屏时红绿灯压在侧栏顶部，图标下移但仍然显示
            if !state.isPinned || state.isFullscreen {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 27, height: 27)
                    .padding(.top, state.isFullscreen ? 48 : 12)
                    .accessibilityLabel("Aurora")
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if draggingModule != nil {
                Text(T("拖出侧栏停用"))
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .offset(x: -14)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 拖动排序 / 拖出停用

    private var panelFrame: CGRect {
        // 面板层级固定是 popUpMenuWindow，用它认窗口最稳（不会认成欢迎窗或自检窗口）
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        let windows = NSApp.windows.filter { $0.isVisible && $0.level == level }
        return (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.frame ?? .zero
    }

    /// 屏幕坐标 → 侧栏坐标（侧栏从面板左上角开始铺满高度）
    private func railPoint(from screenPoint: CGPoint) -> CGPoint {
        let frame = panelFrame
        guard frame != .zero else { return .zero }
        return CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }

    private func handleDragMove(_ module: AuroraModule, to screenPoint: CGPoint) {
        withAnimation(.smooth(duration: 0.14)) {
            draggingModule = module
        }
        guard let index = dropIndex(at: railPoint(from: screenPoint)) else { return }
        state.settings.moveModule(module, to: index)
    }

    private func handleDragEnd(_ module: AuroraModule, at screenPoint: CGPoint) {
        draggingModule = nil
        let frame = panelFrame
        guard frame != .zero else { return }
        // 只要松手位置落在面板外（含拖到桌面、其它 App 上），就询问是否停用
        if !frame.insetBy(dx: -10, dy: -10).contains(screenPoint) {
            confirmDisable(module)
        }
    }

    private func dropIndex(at point: CGPoint) -> Int? {
        let middle = state.visibleModules.filter(\.isToggleable)
        guard !middle.isEmpty else { return nil }
        var best: (Int, CGFloat)?
        for (index, module) in middle.enumerated() {
            guard let frame = railFrames[module.rawValue] else { continue }
            let distance = abs(frame.midY - point.y)
            if best == nil || distance < best!.1 { best = (index, distance) }
        }
        return best?.0
    }

    /// 拖出侧栏：用系统弹窗确认后再停用
    private func confirmDisable(_ module: AuroraModule) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = TF("停用「%@」模块？", T(module.title))
            alert.informativeText = T("它会从左边的图标栏移除，随时可以在设置里重新打开。")
            alert.addButton(withTitle: T("停用"))
            alert.addButton(withTitle: T("取消"))
            // 面板层级是 popUpMenuWindow，确认框必须再高一层才不会被压住
            let panelLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
            alert.window.level = NSWindow.Level(rawValue: panelLevel + 1)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            state.settings.setModule(module, enabled: false)
            if state.module == module { state.select(.overview) }
            state.showToast(TF("已停用「%@」", T(module.title)), symbol: "eye.slash")
        }
    }

    private func railButton(_ module: AuroraModule) -> some View {
        let selected = state.module == module
        return Button {
            state.select(module)
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AuroraTheme.accent.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AuroraTheme.accent.opacity(0.35), lineWidth: 0.8)
                        }
                }
                Image(systemName: module.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
            }
            .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .help(T(module.title))
        .accessibilityLabel(T(module.title))
    }

    /// 全局快捷键设置入口（与设置页同层的单层内容页）
    private var hotkeyRailButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) { state.showHotkeys = true }
        } label: {
            ZStack {
                if state.showHotkeys {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AuroraTheme.accent.opacity(0.16))
                }
                Image(systemName: "command.square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(state.showHotkeys ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
            }
            .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .help(T("全局快捷键"))
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 9) {
            Text(T(state.showHotkeys ? "全局快捷键" : state.module.title))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .layoutPriority(1)

            if !state.showHotkeys, state.module.isBeta {
                Text("Beta")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
                    .help(T("功能仍在完善，欢迎反馈"))
            }

            Spacer(minLength: 4)

            liveChip(symbol: "cpu", value: Fmt.percent(monitor.cpu))
            liveChip(symbol: "memorychip", value: Fmt.percent(monitor.memory.usage))

            pinButton

            Button {
                state.imports.scan(displays: state.display.displays)
                withAnimation(.smooth(duration: 0.26)) { state.showImport = true }
            } label: {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(T("从同类工具导入配置"))

            Button {
                state.requestQuit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(T("退出 Aurora"))
        }
        // 红绿灯始终跟随主顶栏，覆盖页面不再改变其垂直位置。
        .background(WindowHeaderAlignment())
        // 固定成普通窗口后，左上角是系统红绿灯，标题往右让开
        .padding(.leading, state.isPinned ? 44 : 16)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(height: 50)
        .background { Color.clear }
    }

    private var pinButton: some View {
        Button {
            state.togglePinned()
        } label: {
            Image(systemName: state.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.isPinned ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background {
                    Circle().fill(
                        state.isPinned
                            ? AnyShapeStyle(AuroraTheme.accent.opacity(0.16))
                            : AnyShapeStyle(Color.primary.opacity(0.06))
                    )
                }
                .overlay {
                    Circle().strokeBorder(
                        state.isPinned ? AuroraTheme.accent.opacity(0.38) : Color.clear,
                        lineWidth: 0.7
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(pointer.isCapturing)
        .opacity(pointer.isCapturing ? 0.4 : 1)
        .help(state.isPinned ? T("取消固定，回到浮动面板") : T("固定成独立窗口"))
        .accessibilityLabel(T("固定"))
    }

    private func liveChip(symbol: String, value: String) -> some View {
        Button {
            state.select(.overview)
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(AuroraTheme.accent)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                if state.showHotkeys {
                    HotkeySettingsView(hotkeys: state.hotkeys)
                } else {
                    switch state.module {
                    case .overview:
                        OverviewView(state: state)
                    case .display:
                        DisplayView(state: state)
                    case .pointer:
                        PointerView(state: state)
                    case .trackpad:
                        TrackpadView(service: state.trackpad)
                    case .keyboard:
                        KeyboardView(state: state)
                    case .menu:
                        ContextMenuView(state: state)
                    case .desktop:
                        DesktopView(state: state)
                    case .clipboard:
                        ClipboardView(state: state)
                    case .screenshot:
                        ScreenshotView(state: state)
                    case .recorder:
                        RecorderView(state: state)
                    case .energy:
                        EnergyView(state: state)
                    case .audio:
                        AudioView(state: state)
                    case .ai:
                        AIView(state: state)
                    case .settings:
                        SettingsView(state: state)
                    }
                }
            }
            .padding(.top, 54)
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in contentWidth = new }
            }
        }
        .environment(\.auroraContentWidth, contentWidth)
        // 顶部软边缘：内容滚到标题栏下时逐渐淡出（玻璃窗口内无法对同窗口内容做实时模糊，
        // 这里用固定 54pt 的渐隐遮罩做出等价的「软边」观感；静止时首张卡片不受影响）
        .mask {
            GeometryReader { proxy in
                let h = max(proxy.size.height, 1)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.42), location: 16 / h),
                        .init(color: .black, location: 52 / h),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .id(state.module)
        .transition(.opacity)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 捕获提示

    /// 捕获鼠标按键时的悬浮提示：说明当前在等按键，并给一个逃生口
    private var captureHUD: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(AuroraTheme.accent)
                    .frame(width: 6, height: 6)
                Circle()
                    .stroke(AuroraTheme.accent, lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .scaleEffect(capturePulse ? 2.6 : 1)
                    .opacity(capturePulse ? 0 : 0.7)
            }
            .frame(width: 14, height: 14)

            Text(T("按下鼠标上的按键完成捕获"))
                .font(.system(size: 11, weight: .medium))

            Text("esc")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }

            Button(T("取消")) { state.endButtonCapture() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AuroraTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { Capsule().fill(.ultraThinMaterial) }
        .overlay { Capsule().strokeBorder(AuroraTheme.accent.opacity(0.42), lineWidth: 0.8) }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .onAppear {
            capturePulse = false
            withAnimation(.easeOut(duration: 1.15).repeatForever(autoreverses: false)) {
                capturePulse = true
            }
        }
    }

    // MARK: - 提示

    private func toastView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.toastSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuroraTheme.accent)
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { Capsule().fill(.ultraThinMaterial) }
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7) }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// 侧边栏每一格的窗口坐标，拖动排序时用来算落点
private struct RailFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
