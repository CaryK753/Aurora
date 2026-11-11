//  RecorderView.swift
//  Aurora — 录屏模块页：录制源、选项、开始 / 停止、最近录像
//
//  功能参考 QuickRecorder / Recordly：屏幕 / 窗口两种录制源、系统声音与
//  麦克风、指针显隐、Retina 高分辨率、帧率与编码选择、录制悬浮指示器。

import SwiftUI
import AppKit
import ScreenCaptureKit

struct RecorderView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var recorder = RecorderService.shared
    @ObservedObject private var permissions: PermissionService
    @State private var recentFiles: [URL] = []

    init(state: AppState) {
        self.state = state
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            controlCard
            if !recorder.isRecording { sourceCard }
            optionsCard
            recentCard
        }
        .onAppear {
            recorder.refreshSources()
            reloadRecent()
        }
        .onReceive(recorder.$lastMovieURL) { _ in reloadRecent() }
    }

    // MARK: 控制卡

    private var controlCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(recorder.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(AuroraTheme.accentGradient))
                        )
                        .shadow(color: (recorder.isRecording ? Color.red : AuroraTheme.accent).opacity(0.3), radius: 5, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("录屏"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(T("屏幕或窗口录制，系统声音与麦克风，MP4 保存"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)

                    if recorder.isRecording {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                            Text(recorder.elapsedText)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                }

                if !permissions.screenRecording {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(AuroraTheme.warn)
                            Text(T("需要「屏幕录制」权限才能录屏"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(T("去授权")) {
                                permissions.requestScreenRecording()
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                        Text(T("录屏与截图共用这一项权限；画面只在本机处理，不会上传。"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AuroraTheme.warn.opacity(0.1))
                    }
                }

                if let error = recorder.lastError {
                    Text(error)
                        .font(.system(size: 9.5))
                        .foregroundStyle(AuroraTheme.danger)
                }
                if let note = recorder.statusNote {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        // 主面板开着会把自己录进去，先收起
                        auroraDelegate?.panelWillCaptureScreenshot()
                        recorder.start()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(recorder.isRecording ? T("停止录制") : T("开始录制"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(recorder.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(AuroraTheme.accentGradient))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!permissions.screenRecording && !recorder.isRecording)
                .opacity(!permissions.screenRecording && !recorder.isRecording ? 0.5 : 1)

                Text(T("录制时屏幕底部会显示控制条，可暂停或丢弃，随时点停止。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)

                Button {
                    RecorderBar.shared.show()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "menubar.dock.rectangle.badge.record")
                            .font(.system(size: 10, weight: .semibold))
                        Text(T("打开悬浮控制条"))
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 源选择

    private var sourceCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("录制源"), symbol: "rectangle.on.rectangle")
                    Spacer()
                    Button {
                        recorder.selectArea()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 9, weight: .semibold))
                            Text(T("框选区域"))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(T("拖拽选择录制区域"))
                    Button {
                        recorder.refreshSources()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(T("刷新窗口与屏幕列表"))
                }

                if recorder.selectedSourceID == RecorderService.areaSourceID, let rect = recorder.areaRect {
                    Text(TF("当前区域 %d × %d", Int(rect.width), Int(rect.height)))
                        .font(.system(size: 8.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                if recorder.sources.isEmpty {
                    Text(T("没有可录制的屏幕或窗口，请检查权限后刷新"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(recorder.sources) { source in
                                sourceRow(source)
                            }
                        }
                    }
                    .frame(maxHeight: 176)
                }
            }
        }
    }

    private func sourceRow(_ source: RecorderSource) -> some View {
        let selected = recorder.selectedSourceID == source.id
        return Button {
            recorder.selectedSourceID = source.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: source.kind == .display ? "display" : "macwindow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(source.subtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AuroraTheme.accent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AuroraTheme.accent.opacity(0.13) : Color.primary.opacity(0.03))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 选项

    private var optionsCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: T("录制选项"), symbol: "slider.horizontal.3")

                optionRow(symbol: "speaker.wave.2", label: T("系统声音"), detail: T("录进 MP4 音轨；窗口录制不支持系统声音")) {
                    AuroraToggle(isOn: $recorder.systemAudio)
                }
                Divider().opacity(0.4)
                optionRow(symbol: "mic", label: T("麦克风"), detail: T("混入同一个 MP4（第二音轨），输出只有一个文件")) {
                    AuroraToggle(isOn: $recorder.recordMic)
                }
                Divider().opacity(0.4)
                optionRow(symbol: "cursorarrow.click", label: T("显示指针"), detail: T("把鼠标指针录进画面")) {
                    AuroraToggle(isOn: $recorder.showCursor)
                }
                Divider().opacity(0.4)
                optionRow(symbol: "rectangle.landscape.rotate", label: T("Retina 高分辨率"), detail: T("按显示器原生像素录制，文件更大更清晰")) {
                    AuroraToggle(isOn: $recorder.hiRes)
                }
                Divider().opacity(0.4)
                optionRow(symbol: "cursorarrow.click.2", label: T("点击高亮"), detail: T("录制时在鼠标点击处播放涟漪动画")) {
                    AuroraToggle(isOn: $recorder.highlightClicks)
                }
                Divider().opacity(0.4)
                optionRow(symbol: "video.fill.badge.plus", label: T("画中画摄像头"), detail: T("录制时屏幕角落悬浮摄像头气泡，一并录进画面")) {
                    AuroraToggle(isOn: $recorder.pipCamera)
                }
                Divider().opacity(0.4)
                optionRow(symbol: "keyboard", label: T("显示按键"), detail: T("按下的组合键实时显示在屏幕底部（需要辅助功能权限）")) {
                    AuroraToggle(isOn: $recorder.showKeystrokes)
                }

                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(T("帧率"))
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    segmentPicker(
                        options: ["30", "60"],
                        current: recorder.fps >= 60 ? 1 : 0
                    ) { recorder.fps = ($0 == 1) ? 60 : 30 }
                }

                HStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(T("编码"))
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    segmentPicker(
                        options: [T("H.265（更小）"), T("H.264（兼容）")],
                        current: recorder.useHEVC ? 0 : 1
                    ) { recorder.useHEVC = ($0 == 0) }
                }
            }
        }
    }

    private func optionRow(symbol: String, label: String, detail: String, @ViewBuilder toggle: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            toggle()
        }
    }

    private func segmentPicker(options: [String], current: Int, select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, title in
                Button {
                    select(index)
                } label: {
                    Text(title)
                        .font(.system(size: 9.5, weight: current == index ? .semibold : .medium))
                        .foregroundStyle(current == index ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.7)))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            Capsule().fill(current == index ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.clear))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: 最近录像

    private var recentCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("最近录像"), symbol: "movie")
                    Spacer()
                    Button(T("打开文件夹")) {
                        NSWorkspace.shared.open(recorder.outputDirectory)
                    }
                    .font(.system(size: 9, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(AuroraTheme.accent)
                }

                if recentFiles.isEmpty {
                    Text(T("录像会保存到「影片 › Aurora Recordings」"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 3) {
                        ForEach(recentFiles, id: \.self) { url in
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: url.pathExtension == "m4a" ? "waveform" : "film")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                                       let size = attrs[.size] as? Int {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                            .font(.system(size: 8, design: .rounded))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.03))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func reloadRecent() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recorder.outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        recentFiles = Array(files
            .filter { ["mp4", "mov", "m4a"].contains($0.pathExtension) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(6))
    }
}
