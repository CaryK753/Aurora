//  RecorderBar.swift
//  Aurora — 录制悬浮控制条：Recordly 式独立 Bar（液态玻璃）
//
//  两个状态（参考 Recordly LaunchWindow）：
//  · 待机态：大录音键 + 录制源 + 麦克风 / 系统声音开关 + 隐藏
//  · 录制态：停止 + 计时 + 暂停 / 恢复 + 丢弃
//  非激活面板不抢焦点，可拖动挪位置；状态切换时窗口宽度跟随内容变化。

import AppKit
import SwiftUI

@MainActor
final class RecorderBar {
    static let shared = RecorderBar()

    private var panel: NSPanel?
    private var stateObserver: Any?

    /// 待机态 / 录制态各自的宽度
    static let idleSize = CGSize(width: 392, height: 52)
    static let recordingSize = CGSize(width: 268, height: 52)

    /// 控制条跟着录制所在的那块屏（多屏时不固定主屏）
    static var targetScreen: NSScreen?

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        panel.setFrame(Self.frame(for: RecorderService.shared.isRecording), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        installStateObserverIfNeeded()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    func update(text: String) {
        NotificationCenter.default.post(name: .recorderBarElapsed, object: text)
    }

    /// 状态切换时窗口宽度跟随内容
    private func installStateObserverIfNeeded() {
        guard stateObserver == nil else { return }
        stateObserver = RecorderService.shared.$isRecording.sink { [weak self] recording in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            panel.setFrame(Self.frame(for: recording), display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = RecorderBarPanel(
            contentRect: Self.frame(for: false),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 背景拖动会吞掉按钮的点击，改用独立的拖拽把手
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false

        // 液态玻璃底 + SwiftUI 内容（与主面板同款结构）
        let size = RecorderBar.idleSize
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.tintColor = NSColor.white.withAlphaComponent(0.04)
        if glass.responds(to: Selector(("setEffectIsInteractive:"))) {
            glass.setValue(false, forKey: "effectIsInteractive")
        }
        glass.autoresizingMask = [.width, .height]

        let hosting = TransparentHostingView(rootView: RecorderBarView())
        hosting.safeAreaRegions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        container.addSubview(glass)
        container.addSubview(hosting, positioned: .above, relativeTo: glass)
        panel.contentView = container
        return panel
    }

    /// 录制所在屏幕底部居中，离 Dock 上方一点
    private static func frame(for recording: Bool) -> NSRect {
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = recording ? recordingSize : idleSize
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + 14,
            width: size.width,
            height: size.height
        )
    }
}

extension Notification.Name {
    static let recorderBarElapsed = Notification.Name("aurora.recorder.bar.elapsed")
}

/// 非激活但可以成为 key 的面板：不抢前台 App 焦点，同时保证 SwiftUI 控件可点
final class RecorderBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制条界面

struct RecorderBarView: View {
    @ObservedObject private var recorder = RecorderService.shared
    @State private var pulse = false
    @State private var elapsed = "0:00"

    var body: some View {
        Group {
            if recorder.isRecording {
                recordingControls
            } else {
                idleControls
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recorderBarElapsed)) { note in
            if let text = note.object as? String { elapsed = text }
        }
    }

    // MARK: 录制态（参考 Recordly RecordingControls：停止 + 计时 + 暂停 + 丢弃）

    private var recordingControls: some View {
        HStack(spacing: 10) {
            WindowDragHandle()
                .frame(width: 12)
            Button {
                recorder.stop()
            } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .help(T("停止录制"))

            Text(recorder.isPaused ? T("已暂停") : elapsed)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 46)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 0.8, height: 20)

            barButton(recorder.isPaused ? "play.fill" : "pause.fill", tint: .primary.opacity(0.75)) {
                recorder.togglePause()
            } help: {
                recorder.isPaused ? T("继续录制") : T("暂停录制")
            }

            barButton("trash", tint: .primary.opacity(0.75)) {
                recorder.stop(discard: true)
            } help: {
                T("丢弃这段录制")
            }
        }
        .padding(.horizontal, 16)
        .frame(width: RecorderBar.recordingSize.width, height: RecorderBar.recordingSize.height)
    }

    // MARK: 待机态（参考 Recordly LaunchWindow：录音键 + 源 + 开关）

    private var idleControls: some View {
        HStack(spacing: 8) {
            // 拖拽把手（背景拖动会吞点击，单独留一条）
            WindowDragHandle()
                .frame(width: 14)
                .help(T("拖动移动控制条"))

            Button {
                auroraDelegate?.panelWillCaptureScreenshot()
                recorder.start()
            } label: {
                Circle()
                    .fill(AuroraTheme.accentGradient)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    }
                    .shadow(color: AuroraTheme.accent.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help(T("开始录制"))

            // 录制源：点开菜单直接换，名称完整显示
            Menu {
                Section(T("屏幕")) {
                    ForEach(recorder.sources.filter { $0.kind == .display }) { source in
                        Button {
                            recorder.selectedSourceID = source.id
                        } label: {
                            Label(source.title, systemImage: "display")
                        }
                    }
                }
                if recorder.sources.contains(where: { $0.kind == .window }) {
                    Section(T("窗口")) {
                        ForEach(recorder.sources.filter { $0.kind == .window }) { source in
                            Button {
                                recorder.selectedSourceID = source.id
                            } label: {
                                Label(source.title, systemImage: "macwindow")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    recorder.selectArea()
                } label: {
                    Label(recorder.areaRect == nil ? T("框选录制区域…") : T("重新框选区域…"), systemImage: "viewfinder")
                }
                Button {
                    recorder.refreshSources()
                } label: {
                    Label(T("刷新列表"), systemImage: "arrow.clockwise")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sourceSymbol)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(sourceLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary.opacity(0.85))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 168, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(T("点击更换录制源"))

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 0.8, height: 22)

            toggleButton(symbol: "mic.fill", active: recorder.recordMic) {
                recorder.recordMic.toggle()
            }
            toggleButton(symbol: "video.fill", active: recorder.pipCamera) {
                recorder.pipCamera.toggle()
            }
            toggleButton(symbol: "speaker.wave.2.fill", active: recorder.systemAudio) {
                recorder.systemAudio.toggle()
            }
            toggleButton(symbol: "viewfinder", active: recorder.selectedSourceID == RecorderService.areaSourceID) {
                recorder.selectArea()
            }

            barButton("xmark", tint: .primary.opacity(0.5)) {
                RecorderBar.shared.hide()
            } help: {
                T("关闭控制条")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: RecorderBar.idleSize.width, height: RecorderBar.idleSize.height)
    }

    /// 录制源显示名：区域带尺寸，窗口带标题，屏幕带名字
    private var sourceLabel: String {
        guard let source = recorder.selectedSource else { return T("选择录制源") }
        if source.kind == .area, let rect = recorder.areaRect {
            return TF("%@ · %d×%d", source.title, Int(rect.width), Int(rect.height))
        }
        return source.title
    }

    private var sourceSymbol: String {
        switch recorder.selectedSource?.kind {
        case .window: return "macwindow"
        case .area: return "viewfinder"
        default: return "display"
        }
    }

    private func toggleButton(symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.35)))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(active ? T("已开启") : T("已关闭"))
    }

    private func barButton(_ symbol: String, tint: Color, action: @escaping () -> Void, help: @escaping () -> String) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help())
    }
}
