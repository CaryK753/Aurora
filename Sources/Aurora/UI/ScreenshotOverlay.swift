//  ScreenshotOverlay.swift
//  Aurora — 截图会话：选区覆盖层、全屏捕获、长截图浮条、编辑器调度
//
//  覆盖层每块屏一个（screenSaver 层），拖拽选区 → 松手即采集；采集前先收起
//  覆盖层，避免把自己截进去。长截图 = 固定区域反复采集，由底部浮条控制节奏。

import AppKit
import SwiftUI

// MARK: - 会话

@MainActor
final class ScreenshotSession {
    static let shared = ScreenshotSession()

    private var overlays: [RegionOverlayWindow] = []
    private var stitchBar: StitchBarWindow?
    private var editor: EditorWindow?
    /// 长截图：固定捕获区域 + 已捕获的分段
    private var stitchRect: CGRect?
    private var segments: [CGImage] = []
    /// 覆盖层显示期间的 Esc 监听：边框窗口不一定会成为 key window，
    /// 只靠 NSWindow.keyDown 收不到 Esc（这是之前「按 Esc 没反应」的主因）
    private var keyMonitor: Any?

    var isCapturing: Bool { !overlays.isEmpty }

    // MARK: 区域截图

    func startRegionCapture(longMode: Bool = false, windowOnly: Bool = false) {
        guard !isCapturing else { return }
        guard ScreenshotService.hasScreenCapturePermission() else {
            ScreenshotService.requestScreenCapturePermission()
            NotificationCenter.default.post(name: .auroraScreenshotPermissionNeeded, object: nil)
            return
        }
        if longMode {
            stitchRect = nil
            segments = []
        }
        hidePanelIfVisible()
        Task { @MainActor in
            // 先取一次可选窗口列表（点窗口直接截整个 App 窗口）
            let windows = await ScreenshotService.selectableWindows()
            guard isCapturing == false else { return }
            installEscapeMonitor()
            overlays = NSScreen.screens.map { screen in
                RegionOverlayWindow(screen: screen, windows: windows, windowOnly: windowOnly) { [weak self] rect in
                    self?.commitSelection(rect, longMode: longMode)
                } onCancel: { [weak self] in
                    self?.cancel()
                }
            }
            // 先把自己激活成前台 App，否则按键事件仍在别人那里
            NSApp.activate(ignoringOtherApps: true)
            overlays.forEach { $0.makeKeyAndOrderFront(nil) }
            overlays.first?.makeFirstResponder(overlays.first?.contentView)
        }
    }

    func startFullscreenCapture() {
        guard ScreenshotService.hasScreenCapturePermission() else {
            ScreenshotService.requestScreenCapturePermission()
            NotificationCenter.default.post(name: .auroraScreenshotPermissionNeeded, object: nil)
            return
        }
        hidePanelIfVisible()
        // 全屏取鼠标所在屏
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        Task { @MainActor in
            // 等主面板收起、覆盖层消失
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let image = await ScreenshotService.capture(rect: screen.frame) else { return }
            self.presentEditor(image: image)
        }
    }

    private func hidePanelIfVisible() {
        // 主面板开着的时候截图，会把自己截进去
        auroraDelegate?.panelWillCaptureScreenshot()
    }

    private func commitSelection(_ rect: CGRect, longMode: Bool) {
        removeEscapeMonitor()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        // 等覆盖层真正离开屏幕再采
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let image = await ScreenshotService.capture(rect: rect) else {
                self.cancel()
                return
            }
            if longMode {
                self.stitchRect = rect
                self.segments.append(image)
                self.showStitchBar()
            } else {
                self.presentEditor(image: image)
            }
        }
    }

    func cancel() {
        removeEscapeMonitor()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        stitchBar?.orderOut(nil)
        stitchBar = nil
        stitchRect = nil
        segments = []
    }

    // MARK: Esc 取消

    private func installEscapeMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // 53 = Esc：吞掉事件，避免继续传到别的 App
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: 长截图

    private func showStitchBar() {
        installEscapeMonitor()
        if stitchBar == nil {
            stitchBar = StitchBarWindow(
                onCapture: { [weak self] in self?.captureNextSegment() },
                onFinish: { [weak self] in self?.finishStitch() },
                onCancel: { [weak self] in self?.cancel() }
            )
            stitchBar?.makeKeyAndOrderFront(nil)
        }
        stitchBar?.updateCount(segments.count)
    }

    private func captureNextSegment() {
        guard let rect = stitchRect else { return }
        stitchBar?.orderOut(nil)
        stitchBar = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let image = await ScreenshotService.capture(rect: rect) else { return }
            self.segments.append(image)
            self.showStitchBar()
        }
    }

    private func finishStitch() {
        removeEscapeMonitor()
        stitchBar?.orderOut(nil)
        stitchBar = nil
        let captured = segments
        stitchRect = nil
        segments = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ScreenshotService.stitch(captured)
            Task { @MainActor in
                guard let self, let result else { return }
                self.presentEditor(image: result.image)
            }
        }
    }

    // MARK: 编辑器

    func presentEditor(image: CGImage) {
        editor?.close()
        let window = EditorWindow(image: image)
        editor = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let auroraScreenshotPermissionNeeded = Notification.Name("aurora.screenshot.permissionNeeded")
}

// MARK: - 选区覆盖层

final class RegionOverlayWindow: NSWindow {
    /// windowOnly = ⌘⇧5 的「截取所选窗口」模式：只挑窗口，不支持拖拽选区
    init(screen: NSScreen,
         windows: [ScreenshotService.SelectableWindow],
         windowOnly: Bool = false,
         hint: String? = nil,
         onCommit: @escaping (CGRect) -> Void,
         onCancel: @escaping () -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        onEscape = onCancel
        contentView = NSHostingView(rootView: SelectionOverlayView(
            windowFrame: screen.frame,
            windows: windows,
            windowOnly: windowOnly,
            hint: hint,
            onCommit: { rect in onCommit(rect) },
            onCancel: onCancel
        ))
    }

    override var canBecomeKey: Bool { true }

    /// Esc / 取消操作：SwiftUI 的 onKeyPress 依赖焦点，边框窗口里经常收不到，
    /// 这里在窗口层兜底（框选区域、长截图取消都走这里）
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    /// 右键取消，和系统截图行为一致
    override func rightMouseDown(with event: NSEvent) {
        onEscape?()
    }
}

struct SelectionOverlayView: View {
    let windowFrame: NSRect
    /// 可选窗口（SC 全局坐标，左上原点）
    let windows: [ScreenshotService.SelectableWindow]
    var windowOnly: Bool = false
    /// 覆盖默认提示语（录屏选区等场景复用同一覆盖层）
    var hint: String? = nil
    var onCommit: (CGRect) -> Void
    var onCancel: () -> Void

    struct Highlight: Equatable {
        let rect: CGRect     // 本 overlay 局部坐标
        let label: String
    }

    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var highlight: Highlight?

    private var selectionRect: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        )
    }

    // SC（左上原点全局）与 NS（左下原点全局）互转
    private var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? windowFrame.maxY
    }
    /// 本屏左上角在 SC 坐标系里的 y
    private var screenSCTop: CGFloat { primaryHeight - windowFrame.maxY }

    /// 悬停点（局部）命中的窗口
    private func windowHit(at local: CGPoint) -> Highlight? {
        let scPoint = CGPoint(x: windowFrame.minX + local.x, y: screenSCTop + local.y)
        let hit = windows
            .filter { $0.frame.contains(scPoint) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let hit else { return nil }
        let rect = CGRect(
            x: hit.frame.minX - windowFrame.minX,
            y: hit.frame.minY - screenSCTop,
            width: hit.frame.width,
            height: hit.frame.height
        )
        return Highlight(rect: rect, label: hit.label)
    }

    /// 窗口 SC rect → 全局 NS rect（交给 capture(rect:)）
    private func nsRect(fromSC rect: CGRect) -> NSRect {
        NSRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 压暗全屏
            Color.black.opacity(0.28)

            if let rect = selectionRect, rect.width > 2, rect.height > 2 {
                // 选中区透亮
                                Rectangle()
                    .fill(Color.clear)
                    .frame(width: rect.width, height: rect.height)
                    .overlay {
                        Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    }
                    .overlay {
                        Rectangle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.7)
                    }
                    .offset(x: rect.minX, y: rect.minY)

                // 尺寸角标
                Text("\(Int(rect.width)) × \(Int(rect.height))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .offset(
                        x: rect.minX + rect.width / 2 - 44,
                        y: rect.minY + rect.height + 8 > windowFrame.height - 30
                            ? rect.minY - 30
                            : rect.minY + rect.height + 8
                    )
            } else if let highlight {
                // 窗口高亮：点一下直接截整个窗口
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                    }
                    .frame(width: highlight.rect.width, height: highlight.rect.height)
                    .offset(x: highlight.rect.minX, y: highlight.rect.minY)

                Text(highlight.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.66)))
                    .offset(
                        x: min(max(highlight.rect.minX + 8, 8), windowFrame.width - 240),
                        y: highlight.rect.minY > 34
                            ? highlight.rect.minY - 26
                            : highlight.rect.minY + 8
                    )
            }

            if start == nil && highlight == nil {
                Text(hint ?? T(windowOnly
                    ? "点击要截取的窗口 · Esc 取消"
                    : "点击窗口直接截图 · 拖拽选区 · Esc 取消"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard start == nil else { return }
                highlight = windowHit(at: location)
            case .ended:
                break
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if start == nil {
                        start = value.startLocation
                    }
                    if !windowOnly {
                        // 保留高亮：单击松手时要靠它截取整个窗口
                        current = value.location
                    }
                }
                .onEnded { value in
                    let rect = selectionRect
                    if !windowOnly, let rect, rect.width >= 6, rect.height >= 6 {
                        // 窗口内坐标 → 全局 NS 坐标
                        onCommit(NSRect(
                            origin: CGPoint(x: windowFrame.minX + rect.minX, y: windowFrame.maxY - rect.maxY),
                            size: rect.size
                        ))
                    } else if let hit = highlight ?? windowHit(at: value.startLocation) {
                        // 没拖动就松手：截取点中的窗口
                        onCommit(nsRect(fromSC: CGRect(
                            x: windowFrame.minX + hit.rect.minX,
                            y: screenSCTop + hit.rect.minY,
                            width: hit.rect.width,
                            height: hit.rect.height
                        )))
                    } else {
                        start = nil
                        current = nil
                    }
                }
        )
        .onKeyPress(keys: [.return, .escape]) { press in
            if press.key == .return {
                onCommit(windowFrame)
            } else {
                onCancel()
            }
            return .handled
        }
        .onExitCommand { onCancel() }
    }
}

// MARK: - 长截图浮条

final class StitchBarWindow: NSWindow {
    private let hosting: NSHostingView<StitchBarView>

    init(onCapture: @escaping () -> Void, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        hosting = NSHostingView(rootView: StitchBarView(
            onCapture: onCapture, onFinish: onFinish, onCancel: onCancel
        ))
        let size = CGSize(width: 340, height: 46)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = hosting
        position()
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = hosting.fittingSize
        setFrameTopLeftPoint(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 28 + size.height
        ))
    }

    func updateCount(_ count: Int) {
        hosting.rootView = StitchBarView(
            onCapture: hosting.rootView.onCapture,
            onFinish: hosting.rootView.onFinish,
            onCancel: hosting.rootView.onCancel,
            count: count
        )
        position()
    }
}

struct StitchBarView: View {
    var onCapture: () -> Void
    var onFinish: () -> Void
    var onCancel: () -> Void
    var count: Int = 1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AuroraTheme.accent)

            Text(T("滚动页面后点「下一屏」"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            if count > 0 {
                Text(TF("%d 屏", count))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
            }

            Button(T("下一屏")) { onCapture() }
                .buttonStyle(SoftButtonStyle())

            Button(T("拼接")) { onFinish() }
                .buttonStyle(SoftButtonStyle(prominent: true))

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.7)
                }
        }
    }
}
