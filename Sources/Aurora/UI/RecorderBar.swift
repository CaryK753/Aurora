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
    static let idleSize = CGSize(width: 408, height: 54)
    static let recordingSize = CGSize(width: 238, height: 54)

    /// 控制条跟着录制所在的那块屏（多屏时不固定主屏）
    static var targetScreen: NSScreen?

    func prepareWindowID() -> CGWindowID? {
        if panel?.isVisible != true { show() }
        return panel.map { CGWindowID($0.windowNumber) }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
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
        panel.orderOut(nil)
    }

    /// 状态切换时窗口宽度跟随内容
    private func installStateObserverIfNeeded() {
        guard stateObserver == nil else { return }
        stateObserver = RecorderService.shared.$isRecording.sink { [weak self] recording in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let size = recording ? Self.recordingSize : Self.idleSize
            let bounds = panel.screen?.visibleFrame ?? Self.frame(for: recording)
            let x = max(bounds.minX, min(panel.frame.midX - size.width / 2, bounds.maxX - size.width))
            let y = max(bounds.minY, min(panel.frame.minY, bounds.maxY - size.height))
            panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
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

        let hosting = TransparentHostingView(rootView: RecorderBarView())
        hosting.safeAreaRegions = []
        hosting.frame = NSRect(origin: .zero, size: Self.idleSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
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

/// 非激活但可以成为 key 的面板：不抢前台 App 焦点，同时保证 SwiftUI 控件可点
final class RecorderBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制条界面

struct RecorderBarView: View {
    @ObservedObject private var recorder = RecorderService.shared
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x3.fill")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 16, height: 40)
                .overlay(WindowDragHandle())
                .help(T("拖动移动控制条"))
            if recorder.isRecording {
                action("stop.fill", T("停止并保存"), accent: true) { recorder.stop() }
                Text(recorder.elapsedText).font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(recorder.isPaused ? .orange : .white)
                    .frame(minWidth: 45)
                divider
                action(recorder.isPaused ? "play.fill" : "pause.fill", recorder.isPaused ? T("继续录制") : T("暂停录制")) {
                    recorder.togglePause()
                }
                Menu {
                    Button(T("丢弃这段录制"), role: .destructive) { recorder.stop(discard: true) }
                } label: { glyph("trash") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else if recorder.isStarting {
                Image(systemName: "timer").foregroundStyle(.orange)
                Text(recorder.remaining > 0 ? TF("%d 秒后开始录制", recorder.remaining) : T("正在启动录制…"))
                    .monospacedDigit()
                if recorder.remaining > 0 { Button(T("取消")) { recorder.cancelCountdown() } }
            } else {
                sourceMenu
                divider
                if !recorder.mobileSelected {
                    action(recorder.recordMic ? "mic.fill" : "mic.slash", T("麦克风"), active: recorder.recordMic) { recorder.recordMic.toggle() }
                    action("video", T("画中画摄像头"), active: recorder.pipCamera) { recorder.pipCamera.toggle() }
                    action("speaker.wave.2", T("系统声音"), active: recorder.systemAudio && recorder.selectedSource?.supportsSystemAudio == true) { recorder.systemAudio.toggle() }
                        .disabled(recorder.selectedSource?.supportsSystemAudio != true)
                }
                Menu {
                    Picker(T("录屏倒计时"), selection: $recorder.countdown) {
                        ForEach([0, 3, 5, 10], id: \.self) { n in Text(n == 0 ? T("关闭") : TF("%d 秒", n)).tag(n) }
                    }
                    Toggle(T("录入 Aurora 窗口"), isOn: $recorder.includeAurora)
                } label: { glyph("timer") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(T("录制设置"))
                Spacer(minLength: 0)
                action("record.circle", T("开始录制"), accent: true) { recorder.start() }
                action("xmark", T("关闭控制条")) { RecorderBar.shared.hide() }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.105).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
    }

    private var sourceMenu: some View {
        Menu {
            ForEach([RecorderSource.Kind.display, .window, .mobile], id: \.self) { kind in
                let entries = recorder.sources.filter { $0.kind == kind }
                if !entries.isEmpty {
                    Section(kind == .display ? T("屏幕") : kind == .mobile ? T("USB 移动设备") : T("窗口")) {
                        ForEach(entries) { source in
                            Button {
                                recorder.selectedSourceID = source.id
                            } label: {
                                if source.id == recorder.selectedSourceID { Label(source.title, systemImage: "checkmark") }
                                else { Text(source.title) }
                            }
                        }
                    }
                }
            }
            Button(T("框选录制区域…")) { recorder.selectArea() }
            Button(T("查找 iPhone / iPad")) { recorder.findMobileDevices() }
            Button(T("刷新列表")) { recorder.refreshSources() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: recorder.mobileSelected ? "iphone" : "macwindow")
                Text(recorder.selectedSource?.title ?? T("选择录制源")).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 21) }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).frame(width: 23, height: 30).contentShape(Rectangle())
    }

    private func action(_ symbol: String, _ name: String, active: Bool = false, accent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            glyph(symbol)
                .frame(width: accent ? 32 : 26, height: 32)
                .foregroundStyle(accent || active ? Color.white : Color.white.opacity(0.72))
                .background(Capsule().fill(accent ? Color.red : .white.opacity(active ? 0.22 : 0.06)))
        }.accessibilityLabel(name).help(name)
    }
}
