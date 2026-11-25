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
    @ObservedObject private var camera = CameraBubble.shared
    @State private var cameraDevices: [CameraBubble.Device] = []
    private struct RecentRecording: Identifiable, Sendable {
        let url: URL
        let modified: Date
        let bytes: Int64?
        var id: URL { url }
    }
    @State private var recentFiles: [RecentRecording] = []
    @State private var overlayAccess = false
    /// 按键显示走「输入监控」，和点击高亮的辅助功能是两项权限
    @State private var keyAccess = false
    @State private var accessRevision = 0
    @State private var bezelError: String?

    init(state: AppState) {
        self.state = state
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            controlCard
            if !recorder.isRecording { sourceCard.disabled(recorder.optionsLocked) }
            optionsCard
            recentCard
        }
        .onAppear { recorder.refreshSources() }
        .task(id: recorder.lastMovieURL) { await reloadRecent() }
        .task(id: recorder.pipCamera) {
            let devices = await readInBackground { CameraBubble.availableDevices() }
            if !Task.isCancelled { cameraDevices = devices }
        }
        .task(id: accessRevision) {
            let access = await readInBackground { (OverlayAccess.hasAccessibility, OverlayAccess.hasKeyboardAccess) }
            guard !Task.isCancelled else { return }
            (overlayAccess, keyAccess) = access
        }
        // 用户去系统设置勾完权限回来，这里跟着刷新。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessRevision &+= 1
        }
        .onChange(of: recorder.showKeystrokes) { _, on in
            if on, !keyAccess { OverlayAccess.requestKeyboardAccess() }
        }
        .onChange(of: recorder.highlightClicks) { _, on in
            if on, !overlayAccess { OverlayAccess.requestAccessibility() }
        }
        // 开关就是气泡的开关：打开立刻出画面（可以先摆好位置），关掉就收起
        .onChange(of: recorder.pipCamera) { _, on in
            if on {
                CameraBubble.shared.show(on: recorder.targetScreen)
            } else {
                CameraBubble.shared.hide()
            }
        }
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

                if !permissions.screenRecording && !recorder.mobileSelected {
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
                if recorder.isWrappingBezel {
                    HStack(spacing: 7) {
                        ProgressView(value: recorder.bezelProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                        Text(TF("%d%%", Int(recorder.bezelProgress * 100)))
                            .font(.system(size: 8.5, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(recorder.remaining > 0 ? TF("取消倒计时（%d）", recorder.remaining) : recorder.isStarting ? T("正在启动录制…") : recorder.isStopping ? T("正在保存…") : recorder.isRecording ? T("停止录制") : T("开始录制"))
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
                .disabled((!permissions.screenRecording && !recorder.mobileSelected && !recorder.isRecording) || (recorder.isStarting && recorder.remaining == 0) || recorder.isStopping)
                .opacity(!permissions.screenRecording && !recorder.mobileSelected && !recorder.isRecording ? 0.5 : 1)

                Text(T("录制时屏幕底部会显示控制条，可暂停或丢弃，随时点停止。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)

                Button {
                    RecorderBar.targetScreen = recorder.targetScreen
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

                Toggle(T("录入 Aurora 窗口"), isOn: $recorder.includeAurora)
                    .toggleStyle(.switch).controlSize(.mini)
                HStack {
                    Text(T("USB 移动设备"))
                    Spacer()
                    Button(T("查找 iPhone / iPad")) { recorder.findMobileDevices() }
                        .disabled(recorder.findingMobile)
                }
                .font(.caption)
                Text(T("用 USB 连接设备并解锁，轻点「信任」，再查找并选择设备。"))
                    .font(.caption2).foregroundStyle(.secondary)
                if let note = recorder.mobileSearchNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
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
                Image(systemName: source.kind == .mobile ? "iphone" : source.kind == .display ? "display" : "macwindow")
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
                if recorder.optionsLocked {
                    Text(T("请停止录制后调整录制选项"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }

                Picker(T("录屏倒计时"), selection: $recorder.countdown) {
                    ForEach([0, 3, 5, 10], id: \.self) { seconds in
                        Text(seconds == 0 ? T("关闭") : TF("%d 秒", seconds)).tag(seconds)
                    }
                }.pickerStyle(.segmented)
                if recorder.mobileSelected {
                    Text(T("录制设备画面和设备提供的声音，保存为 MOV。可在最近录像中编辑和导出。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    optionRow(symbol: "speaker.wave.2", label: T("系统声音"), detail: T("录进 MP4 音轨；窗口录制不支持系统声音")) {
                        AuroraToggle(isOn: Binding(
                            get: { recorder.systemAudio && recorder.selectedSource?.supportsSystemAudio == true },
                            set: { recorder.systemAudio = $0 }
                        ))
                        .disabled(recorder.selectedSource?.supportsSystemAudio != true)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "mic", label: T("麦克风"), detail: T("与系统声音合成为同一条音轨，输出一个 MP4 文件")) {
                        AuroraToggle(isOn: $recorder.recordMic)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "cursorarrow.click", label: T("显示指针"), detail: T("把鼠标指针录进画面")) {
                        AuroraToggle(isOn: $recorder.showCursor).disabled(recorder.editableCursor)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "rectangle.landscape.rotate", label: T("Retina 高分辨率"), detail: T("按显示器原生像素录制，文件更大更清晰")) {
                        AuroraToggle(isOn: $recorder.hiRes)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "plus.magnifyingglass", label: T("鼠标跟随缩放"), detail: T("记录点击，在最近录像中预览和编辑缩放")) {
                        AuroraToggle(isOn: $recorder.trackZoom)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "cursorarrow", label: T("后期编辑光标"), detail: T("只记录位置，在时间线添加光标样式")) {
                        AuroraToggle(isOn: $recorder.editableCursor)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "cursorarrow.click.2", label: T("点击高亮"), detail: T("录制时在鼠标点击处播放涟漪动画")) {
                        AuroraToggle(isOn: $recorder.highlightClicks)
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "video.fill.badge.plus", label: T("画中画摄像头"), detail: T("屏幕角落显示摄像头气泡；放入录制范围内才会录入画面")) {
                        AuroraToggle(isOn: $recorder.pipCamera)
                    }
                    if recorder.pipCamera {
                        cameraOptions
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "macbook", label: T("录完自动加壳"), detail: T("停止后把成片套进设备外壳，原片保留；也可以稍后在「最近录像」里手动加壳")) {
                        AuroraToggle(isOn: $recorder.bezelRecording)
                    }
                    if recorder.bezelRecording {
                        bezelFrameRow
                    }
                    Divider().opacity(0.4)
                    optionRow(symbol: "keyboard", label: T("显示按键"), detail: T("按下的组合键实时显示在屏幕底部，系统快捷键与功能键也会显示（需要输入监控权限）")) {
                        AuroraToggle(isOn: $recorder.showKeystrokes)
                    }

                    if (recorder.showKeystrokes && !keyAccess) || (recorder.highlightClicks && !overlayAccess) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(AuroraTheme.warn)
                            Text(recorder.showKeystrokes && !keyAccess
                                 ? T("按键显示要「输入监控」权限才能录到系统快捷键与功能键")
                                 : T("点击高亮要「辅助功能」权限才能录到你自己的点击"))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button(T("去授权")) {
                                if recorder.showKeystrokes && !keyAccess {
                                    OverlayAccess.requestKeyboardAccess()
                                } else {
                                    OverlayAccess.requestAccessibility()
                                }
                            }
                            .controlSize(.mini)
                        }
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
            .disabled(recorder.optionsLocked)
        }
    }

    /// 带壳用哪一款：默认跟截图页一致（按本机型号自动识别）
    // MARK: 画中画设置

    /// 缩进在「画中画摄像头」下面的一组紧凑设置
    private var cameraOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "video")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text(T("摄像头"))
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 4)
                Picker("", selection: $camera.deviceID) {
                    Text(T("系统默认")).tag(CameraBubble.defaultDeviceID)
                    ForEach(cameraDevices) { device in
                        Text(device.isContinuity ? TF("%@（连续互通）", device.name) : device.name)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 168)
            }

            HStack(spacing: 8) {
                Image(systemName: "square.on.circle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text(T("形状"))
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 4)
                segmentPicker(
                    options: CameraBubble.Shape.allCases.map(\.title),
                    current: CameraBubble.Shape.allCases.firstIndex(of: camera.shape) ?? 0
                ) { index in
                    camera.shape = CameraBubble.Shape.allCases[index]
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text(T("大小"))
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 4)
                Button {
                    camera.mirrored.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "flip.horizontal")
                            .font(.system(size: 9, weight: .semibold))
                        Text(T("镜像"))
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(camera.mirrored ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(camera.mirrored ? 0.0 : 0.06)))
                }
                .buttonStyle(.plain)
                .help(T("左右翻转画面，像照镜子一样"))
                segmentPicker(
                    options: CameraBubble.Size.allCases.map(\.title),
                    current: CameraBubble.Size.allCases.firstIndex(of: camera.size) ?? 1
                ) { index in
                    camera.size = CameraBubble.Size.allCases[index]
                }
            }

            if camera.isDenied {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AuroraTheme.warn)
                    Text(T("没有摄像头权限，画中画不会出现在录像里"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(T("去授权")) { CameraBubble.shared.openCameraSettings() }
                        .controlSize(.mini)
                }
            }

            Text(T("气泡可以拖动摆放，右键改形状 / 尺寸 / 摄像头；录制窗口时只有落在窗口内的气泡会被录进去。"))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 26)
    }

    private var bezelFrameRow: some View {        let frames = ScreenshotService.shared
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(T("外壳款式"))
                    .font(.system(size: 10.5, weight: .medium))
                Text(recorder.areaSpansDisplays && recorder.bezelFrameID == nil
                     ? T("跨屏区域录制不加壳，可手动指定")
                     : TF("自动匹配 · %@", recorder.resolvedBezelFrame?.device ?? T("默认外壳")))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Picker("", selection: Binding(
                get: { recorder.bezelFrameID },
                set: { recorder.bezelFrameID = $0 }
            )) {
                Text(T("自动识别")).tag(String?.none)
                ForEach(frames.frames) { frame in
                    Text(frame.device).tag(Optional(frame.id))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 132)
        }
    }

    private func optionRow(symbol: String, label: String, detail: String, @ViewBuilder toggle: () -> some View) -> some View {        HStack(spacing: 8) {
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
                        ForEach(recentFiles) { file in
                            recentRow(file)
                        }
                    }
                }

                if recorder.isWrappingBezel {
                    HStack(spacing: 7) {
                        ProgressView(value: recorder.bezelProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                        Text(TF("%d%%", Int(recorder.bezelProgress * 100)))
                            .font(.system(size: 8.5, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                if let bezelError {
                    Text(bezelError)
                        .font(.system(size: 8.5))
                        .foregroundStyle(AuroraTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 最近录像的一行：点行进访达，右侧「加壳」给已有录像补一个带壳版本
    private func recentRow(_ file: RecentRecording) -> some View {
        let url = file.url
        let isFramed = url.lastPathComponent.contains("带壳")
        return HStack(spacing: 6) {
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
                    if let size = file.bytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if ["mp4", "mov"].contains(url.pathExtension) {
                Button(T("缩放时间线")) { ZoomTimelineWindow.open(url) }
                    .buttonStyle(.plain)
                    .disabled(recorder.exportingZoom != nil)
            }
            if !isFramed && url.pathExtension == "mp4" {
                Button {
                    bezelError = nil
                    Task { bezelError = await recorder.wrapRecording(url) }
                } label: {
                    Text(recorder.isWrappingBezel ? T("处理中…") : T("加壳"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(recorder.isWrappingBezel ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.accent))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(recorder.isWrappingBezel)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        }
    }

    private func reloadRecent() async {
        let files = await readInBackground {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: RecorderService.recordingsDirectory(), includingPropertiesForKeys: Array(keys)
            )) ?? []
            let recordings = urls.filter { ["mp4", "mov", "m4a"].contains($0.pathExtension) }.map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return RecentRecording(url: url, modified: values?.contentModificationDate ?? .distantPast,
                                       bytes: values?.fileSize.map(Int64.init))
            }
            return Array(recordings.sorted { $0.modified > $1.modified }.prefix(6))
        }
        guard !Task.isCancelled else { return }
        recentFiles = files
    }
}
