//  RecorderService.swift
//  Aurora — 录屏：ScreenCaptureKit 采集 + AVAssetWriter 落盘
//
//  参考 QuickRecorder / Recordly 的主要功能：
//  · 录制源：整块屏幕 / 指定窗口（SCShareableContent）
//  · 系统声音 + 麦克风混进同一个 mp4（两条音轨），输出永远只有一个文件
//  · 暂停 / 恢复、丢弃重录（Recordly 同款交互）
//  · 帧率 30/60、H.264/H.265、高分辨率（Retina 原生像素）、指针显隐
//  · 悬浮控制条（待机态 / 录制态）、录制期间阻止系统休眠
//  · 快捷键开始 / 停止（HotkeyService.recorder）
//
//  采集管线与 QuickRecorder 同款：SCStream 出帧 → AVAssetWriter 写 mp4。

import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import VideoToolbox

// MARK: - 录制源

struct RecorderSource: Identifiable, Equatable {
    enum Kind: String { case display, window, area }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    var display: SCDisplay?
    var window: SCWindow?
    /// 区域录制：全局 NS 坐标矩形
    var rect: CGRect?
}

// MARK: - 暂停时间轴（参考 Snapzy 的 RecordingPauseTimeline）
//
// 暂停不是丢帧了事：按采样自身的时间戳把暂停区间从成片里裁掉，
// 输出视频连续、无 PTS 断档，且视频与两条音轨共用同一条时间轴保持同步。
// SCStream / AVCaptureSession 的时间戳都基于 host time clock，可以直接比较。

nonisolated struct RecorderPauseTimeline {
    private(set) var accumulatedOffset: CMTime = .zero
    private var pausedAt: CMTime?
    private var resumedAt: CMTime?
    private(set) var lastVideoTime: CMTime?

    var isPaused: Bool { pausedAt != nil }

    mutating func pause() {
        guard pausedAt == nil else { return }
        pausedAt = CMClockGetTime(CMClockGetHostTimeClock())
    }

    mutating func resume() {
        guard let pausedAt else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let pausedDuration = CMTimeSubtract(now, pausedAt)
        if pausedDuration > .zero {
            accumulatedOffset = CMTimeAdd(accumulatedOffset, pausedDuration)
        }
        self.pausedAt = nil
        resumedAt = CMTimeMaximum(now, pausedAt)
    }

    /// 样本的输出时间戳；暂停期间（及暂停前积压）的样本返回 nil 丢弃
    func outputTime(for sourceTime: CMTime) -> CMTime? {
        guard sourceTime.isNumeric else { return nil }
        if let pausedAt, sourceTime >= pausedAt { return nil }
        if let resumedAt, sourceTime < resumedAt { return nil }
        return accumulatedOffset > .zero ? CMTimeSubtract(sourceTime, accumulatedOffset) : sourceTime
    }

    /// 视频轨还要求 PTS 严格递增，否则 AVAssetWriter 直接废掉整个文件
    mutating func acceptVideoFrame(at sourceTime: CMTime) -> CMTime? {
        guard let output = outputTime(for: sourceTime) else { return nil }
        if let lastVideoTime, output <= lastVideoTime { return nil }
        lastVideoTime = output
        return output
    }

    /// 用重映射后的时间戳复制样本
    nonisolated static func retimed(_ buffer: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: time,
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(buffer)
        )
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        ) == noErr else { return nil }
        return out
    }
}

// MARK: - 服务

@MainActor
final class RecorderService: ObservableObject {
    static let shared = RecorderService()

    // MARK: 状态
    @Published private(set) var sources: [RecorderSource] = []
    @Published var selectedSourceID: String {
        didSet { UserDefaults.standard.set(selectedSourceID, forKey: "recorder.source") }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedText = "0:00"
    @Published private(set) var lastMovieURL: URL?
    @Published private(set) var lastError: String?
    /// 最近一次录制的状态提示（写盘中 / 已保存 / 已丢弃）
    @Published private(set) var statusNote: String?
    /// 区域录制：最近一次框选的矩形（全局 NS 坐标），不持久化
    @Published private(set) var areaRect: NSRect?

    // MARK: 选项（持久化）
    @Published var systemAudio: Bool { didSet { ud.set(systemAudio, forKey: "recorder.systemAudio") } }
    @Published var recordMic: Bool { didSet { ud.set(recordMic, forKey: "recorder.mic") } }
    @Published var showCursor: Bool { didSet { ud.set(showCursor, forKey: "recorder.cursor") } }
    @Published var hiRes: Bool { didSet { ud.set(hiRes, forKey: "recorder.hiRes") } }
    @Published var fps: Int { didSet { ud.set(fps, forKey: "recorder.fps") } }
    @Published var useHEVC: Bool { didSet { ud.set(useHEVC, forKey: "recorder.hevc") } }
    /// 录制时高亮鼠标点击（Snapzy 同款）
    @Published var highlightClicks: Bool { didSet { ud.set(highlightClicks, forKey: "recorder.clickHighlight") } }
    /// 录制时显示按下的按键（需要辅助功能权限）
    @Published var showKeystrokes: Bool { didSet { ud.set(showKeystrokes, forKey: "recorder.keystrokes") } }
    /// 画中画：录制时悬浮摄像头气泡（Snapzy 同款，会被整屏采集录进画面）
    @Published var pipCamera: Bool { didSet { ud.set(pipCamera, forKey: "recorder.pip") } }
    /// 带壳录制：停止后把成片套进设备外壳（原片保留）
    @Published var bezelRecording: Bool { didSet { ud.set(bezelRecording, forKey: "recorder.bezel") } }
    /// 带壳用的外壳；nil 表示跟着本机自动识别
    @Published var bezelFrameID: String? {
        didSet {
            if let bezelFrameID {
                ud.set(bezelFrameID, forKey: "recorder.bezelFrame")
            } else {
                ud.removeObject(forKey: "recorder.bezelFrame")
            }
        }
    }
    /// 正在合成带壳视频
    @Published private(set) var isWrappingBezel = false
    @Published private(set) var bezelProgress: Double = 0

    private let ud = UserDefaults.standard

    // MARK: 采集管线
    private var stream: SCStream?
    private var mediaQueue: DispatchQueue!
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var movieURL: URL?
    /// 收尾中：mediaQueue 上的追加逻辑看到它就停手——
    /// markAsFinished 之后继续 append 会让 writer 直接 fail（"写入失败"的元凶）
    private var finishing = false
    /// 会话是否已用首个视频帧的时间戳对齐（SCStream 的时间戳是开机以来的
    /// host time，直接用 .zero 建会话会让成片时长变成"开机时长"）
    private var sessionStarted = false
    /// 已写入的视频帧数（诊断用）
    private var appendedVideoFrames = 0
    private var loggedWriterFailure = false

    // MARK: 麦克风采集
    private var micSession: AVCaptureSession?
    private var micQueue: DispatchQueue!
    private var micSink: RecorderMicSink?

    // MARK: 计时 / 其它
    /// 计时按「已完成段 + 当前段」算，暂停时不走表
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var tick: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var sink: RecorderStreamSink?
    /// 停止时丢弃文件（Recordly 的垃圾桶交互）
    private var discardRequested = false
    /// 暂停时间轴（仅在 mediaQueue 上访问，避免与采样追加竞争）
    private var pauseTimeline = RecorderPauseTimeline()

    // MARK: 区域选择
    static let areaSourceID = "area"
    @Published private(set) var isSelectingArea = false
    private var areaOverlays: [NSWindow] = []
    private var areaDisplay: SCDisplay?

    var outputDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let dir = movies.appendingPathComponent("Aurora Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var hasScreenPermission: Bool { CGPreflightScreenCaptureAccess() }
    var hasMicPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private init() {
        selectedSourceID = ud.string(forKey: "recorder.source") ?? ""
        systemAudio = ud.object(forKey: "recorder.systemAudio") as? Bool ?? true
        recordMic = ud.object(forKey: "recorder.mic") as? Bool ?? false
        showCursor = ud.object(forKey: "recorder.cursor") as? Bool ?? true
        hiRes = ud.object(forKey: "recorder.hiRes") as? Bool ?? true
        fps = ud.object(forKey: "recorder.fps") as? Int ?? 60
        useHEVC = ud.object(forKey: "recorder.hevc") as? Bool ?? true
        highlightClicks = ud.object(forKey: "recorder.clickHighlight") as? Bool ?? false
        showKeystrokes = ud.object(forKey: "recorder.keystrokes") as? Bool ?? false
        pipCamera = ud.object(forKey: "recorder.pip") as? Bool ?? false
        bezelRecording = ud.object(forKey: "recorder.bezel") as? Bool ?? false
        bezelFrameID = ud.string(forKey: "recorder.bezelFrame")
        mediaQueue = DispatchQueue(label: "aurora.recorder.media")
        micQueue = DispatchQueue(label: "aurora.recorder.mic")
        refreshSources()

        // 气泡上的 ✕ 要回到开关上；权限 / 设备问题只弹提示，
        // 气泡留在屏幕上显示原因（授权后自动恢复），别把开关一巴掌拍灭
        CameraBubble.shared.onClose = { [weak self] in self?.pipCamera = false }
        CameraBubble.shared.onUnavailable = { message in
            auroraDelegate?.state.showToast(message, symbol: "video.slash")
        }
    }

    // MARK: - 源列表

    func refreshSources() {
        guard hasScreenPermission else {
            sources = []
            return
        }
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var list: [RecorderSource] = []
            for display in content?.displays ?? [] {
                let name = Self.displayName(for: display) ?? T("显示器")
                list.append(RecorderSource(
                    id: "display:\(display.displayID)", kind: .display,
                    title: name, subtitle: T("整块屏幕，含系统声音"),
                    display: display, window: nil
                ))
            }
            for window in content?.windows ?? [] where Self.isRecordableWindow(window) {
                let app = window.owningApplication?.applicationName ?? T("窗口")
                let title = (window.title?.isEmpty == false) ? window.title! : app
                list.append(RecorderSource(
                    id: "window:\(window.windowID)", kind: .window,
                    title: title, subtitle: app,
                    display: nil, window: window
                ))
            }
            self.sources = list
            if self.selectedSourceID.isEmpty || !list.contains(where: { $0.id == self.selectedSourceID }) {
                self.selectedSourceID = list.first?.id ?? ""
            }
        }
    }

    private nonisolated static func isRecordableWindow(_ window: SCWindow) -> Bool {
        guard let app = window.owningApplication else { return false }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return false }
        if window.frame.width < 160 || window.frame.height < 120 { return false }
        if window.windowLayer != 0 { return false }
        return true
    }

    /// SCDisplay 没有名字，用 displayID 回查 NSScreen 的 localizedName
    private nonisolated static func displayName(for display: SCDisplay) -> String? {
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, id == display.displayID {
                return screen.localizedName
            }
        }
        return nil
    }

    var selectedSource: RecorderSource? {
        if selectedSourceID == Self.areaSourceID, let rect = areaRect {
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
            return RecorderSource(
                id: Self.areaSourceID, kind: .area,
                title: T("选定区域"), subtitle: screen?.localizedName ?? "",
                display: nil, window: nil, rect: rect
            )
        }
        return sources.first { $0.id == selectedSourceID }
    }

    // MARK: - 多屏

    /// 录制内容所在的屏幕（覆盖层、控制条、外壳匹配都跟着它走）
    var targetScreen: NSScreen? {
        guard let source = selectedSource else { return NSScreen.main }
        switch source.kind {
        case .display:
            guard let id = source.display?.displayID else { return NSScreen.main }
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
            } ?? NSScreen.main
        case .area:
            guard let rect = source.rect else { return NSScreen.main }
            return Self.screen(covering: rect)
        case .window:
            guard let frame = source.window?.frame else { return NSScreen.main }
            // SCWindow.frame 是左上原点，先换算再找屏
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let center = CGPoint(x: frame.midX, y: top - frame.midY)
            return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        }
    }

    /// 录制内容的尺寸（外壳按宽高比匹配：内建屏配笔记本、外接屏配显示器）
    var recordedContentSize: CGSize? {
        guard let source = selectedSource else { return nil }
        switch source.kind {
        case .display:
            guard let display = source.display else { return nil }
            return CGSize(width: display.width, height: display.height)
        case .window:
            return source.window?.frame.size
        case .area:
            return source.rect?.size
        }
    }

    /// 区域录制是否横跨多块屏幕（这种加壳会张冠李戴，不自动加）
    var areaSpansDisplays: Bool {
        guard let source = selectedSource, source.kind == .area, let rect = source.rect else { return false }
        let hits = NSScreen.screens.filter { $0.frame.intersection(rect).width > 40 }
        return hits.count > 1
    }

    private static func screen(covering rect: CGRect) -> NSScreen? {
        NSScreen.screens
            .map { ($0, $0.frame.intersection(rect)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0 ?? NSScreen.main
    }

    /// 窗口落在哪块 SCDisplay 上（交叠面积最大的一块）
    private static func display(covering rect: CGRect, in content: SCShareableContent?) -> SCDisplay? {
        guard let content else { return nil }
        var best: SCDisplay?
        var bestArea: CGFloat = 0
        for display in content.displays {
            let hit: CGRect = display.frame.intersection(rect)
            guard !hit.isNull else { continue }
            let area: CGFloat = hit.width * hit.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        return best
    }

    private var targetScreenIsBuiltIn: Bool {
        guard let id = targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return true
        }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// 按宽高比挑外壳：内建屏从笔记本里挑，外接屏从显示器 / iMac 里挑
    func suggestedBezelFrame(for content: CGSize) -> DeviceFrame? {
        let frames = ScreenshotService.shared.frames.filter { $0.category == "mac" }
        guard !frames.isEmpty, content.width > 1, content.height > 1 else { return nil }
        let aspect = content.width / content.height
        let wantsLaptop = targetScreenIsBuiltIn
        let pool = frames.filter { $0.device.contains("MacBook") == wantsLaptop }
        let candidates = pool.isEmpty ? frames : pool
        return candidates.min { abs($0.screenAspect - aspect) < abs($1.screenAspect - aspect) }
    }

    // MARK: - 区域选择（拖一个矩形只录这块屏幕）

    func selectArea() {
        guard !isSelectingArea, !isRecording else { return }
        guard hasScreenPermission else {
            lastError = T("需要「屏幕录制」权限才能录屏")
            return
        }
        isSelectingArea = true
        auroraDelegate?.panelWillCaptureScreenshot()
        RecorderBar.shared.hide()
        Task { @MainActor in
            // 需要 SCDisplay 来建区域采集过滤器
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displays = content?.displays ?? []
            self.areaOverlays = NSScreen.screens.map { screen in
                RegionOverlayWindow(screen: screen, windows: [], hint: T("拖拽选择录制区域 · Esc 取消")) { [weak self] rect in
                    self?.commitArea(rect, displays: displays)
                } onCancel: { [weak self] in
                    self?.cancelAreaSelection()
                }
            }
            self.areaOverlays.forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }

    private func commitArea(_ rect: NSRect, displays: [SCDisplay]) {
        areaOverlays.forEach { $0.orderOut(nil) }
        areaOverlays = []
        isSelectingArea = false
        areaRect = rect
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
        areaDisplay = displays.first { $0.displayID == displayID }
        selectedSourceID = Self.areaSourceID
    }

    func cancelAreaSelection() {
        areaOverlays.forEach { $0.orderOut(nil) }
        areaOverlays = []
        isSelectingArea = false
    }

    // MARK: - 开始 / 停止

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        lastError = nil
        guard hasScreenPermission else {
            lastError = T("需要「屏幕录制」权限才能录屏")
            return
        }
        guard selectedSource != nil else {
            lastError = T("先选择一个录制源")
            return
        }
        Task { @MainActor in
            // 麦克风权限要在建 writer 之前敲定：音轨输入必须在 startWriting 前加入
            var micEnabled = false
            if recordMic {
                if hasMicPermission {
                    micEnabled = true
                } else {
                    micEnabled = await AVCaptureDevice.requestAccess(for: .audio)
                }
            }
            await self.beginRecording(micEnabled: micEnabled)
        }
    }

    private func beginRecording(micEnabled: Bool) async {
        guard !isRecording, let source = selectedSource else { return }
        discardRequested = false
        finishing = false
        appendedVideoFrames = 0
        loggedWriterFailure = false

        let stamp = Self.fileStamp()
        let url = outputDirectory.appendingPathComponent("Aurora \(stamp).mp4")
        // AVAssetWriter 要求目标文件不存在，同秒重录会撞名
        try? FileManager.default.removeItem(at: url)
        let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4)
        guard let writer else {
            lastError = T("无法创建录制文件")
            return
        }
        self.movieURL = url
        self.writer = writer

        let conf = SCStreamConfiguration()
        let filter: SCContentFilter
        var areaSourceRect: CGRect?
        var windowSourceRect: CGRect?

        // Aurora 自己的面板、控制条不该出现在录像里。做法与 Snapzy 一致：
        // 整块应用排除，再把要录进去的覆盖层（摄像头气泡 / 按键胶囊 / 点击涟漪）
        // 用 exceptingWindows 单独「例外包含」回来。
        // 覆盖层窗口必须先建出来，否则拿不到它们的 window ID。
        var overlayWindowIDs: [CGWindowID] = []
        var activeOverlayIDs: [CGWindowID] = []   // 这次录制真的会画出来的覆盖层
        if let id = CameraBubble.shared.prepare(on: targetScreen) {
            overlayWindowIDs.append(id)
            if pipCamera { activeOverlayIDs.append(id) }
        }
        if let id = KeystrokeOverlayService.shared.prepare() {
            overlayWindowIDs.append(id)
            if showKeystrokes { activeOverlayIDs.append(id) }
        }
        if let id = ClickHighlightService.shared.prepare() {
            overlayWindowIDs.append(id)
            if highlightClicks { activeOverlayIDs.append(id) }
        }

        let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApps = shareable?.applications.filter {
            guard let bundleID = Bundle.main.bundleIdentifier else { return false }
            return $0.bundleIdentifier == bundleID
        } ?? []
        let overlayWindows = shareable?.windows.filter { overlayWindowIDs.contains($0.windowID) } ?? []

        switch source.kind {
        case .display:
            guard let display = source.display else { return }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApps,
                exceptingWindows: overlayWindows
            )
        case .window:
            guard let window = source.window else { return }
            // 覆盖层落在窗口所在的屏幕上时，改成「显示器 + 只包含这个窗口和覆盖层」，
            // 这样画中画 / 按键胶囊也能出现在窗口录制里；没有覆盖层就沿用窗口级采集
            let onScreenOverlays = overlayWindows.filter {
                activeOverlayIDs.contains($0.windowID) && window.frame.intersects($0.frame)
            }
            if !onScreenOverlays.isEmpty,
               let display = Self.display(covering: window.frame, in: shareable) {
                filter = SCContentFilter(
                    display: display,
                    including: [window] + onScreenOverlays
                )
                windowSourceRect = CGRect(
                    x: window.frame.minX - display.frame.minX,
                    y: window.frame.minY - display.frame.minY,
                    width: window.frame.width,
                    height: window.frame.height
                )
            } else {
                filter = SCContentFilter(desktopIndependentWindow: window)
            }
        case .area:
            guard let rect = source.rect, let display = areaDisplay else { return }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApps,
                exceptingWindows: overlayWindows
            )
            // 全局 NS 坐标 → 该显示屏局部坐标（SC 左上原点）
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
            if let screen {
                areaSourceRect = CGRect(
                    x: rect.minX - screen.frame.minX,
                    y: screen.frame.maxY - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
            }
        }
        // 像素缩放要等 filter 建好才知道（SCContentFilter.pointPixelScale）
        let scale = hiRes ? max(1, Int(filter.pointPixelScale)) : 1
        if let areaSourceRect {
            conf.sourceRect = areaSourceRect
            conf.width = max(2, Int(areaSourceRect.width) * scale)
            conf.height = max(2, Int(areaSourceRect.height) * scale)
        } else if let windowSourceRect {
            conf.sourceRect = windowSourceRect
            conf.width = max(2, Int(windowSourceRect.width) * scale)
            conf.height = max(2, Int(windowSourceRect.height) * scale)
        } else {
            let contentRect = filter.contentRect
            conf.width = Int(contentRect.width) * scale
            conf.height = Int(contentRect.height) * scale
        }
        Debug.log("recorder: source=\(source.kind.rawValue) \(conf.width)x\(conf.height) scale=\(scale) overlays=\(overlayWindowIDs.count) excepted=\(overlayWindows.count)")

        // 编码器要求宽高为偶数：区域框选很容易拖出奇数尺寸，
        // 奇数会走到 startWriting 之后才失败，最后留下一个 0 字节的 mp4
        conf.width = max(2, conf.width - (conf.width % 2))
        conf.height = max(2, conf.height - (conf.height % 2))

        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        conf.queueDepth = 8
        conf.showsCursor = showCursor
        conf.pixelFormat = kCVPixelFormatType_32BGRA
        conf.colorSpaceName = CGColorSpace.sRGB
        conf.capturesAudio = systemAudio && source.kind == .display
        conf.sampleRate = 48000
        conf.channelCount = 2

        // 视频轨：H.265 优先（体积小一半），老机器可换 H.264
        let codec = useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        let bitrate = max(4_000_000, Int(Double(conf.width * conf.height) * Double(fps) * 0.1))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: conf.width,
            AVVideoHeightKey: conf.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
            ]
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video

        // 音轨（系统声音 / 麦克风）都作为同一个 mp4 里的独立音轨；
        // 输入必须在 startWriting 之前加入（AVAssetWriter 的硬性要求）
        if conf.capturesAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        }
        if micEnabled {
            // 采样率 / 声道数必须与麦克风实际格式一致，否则第一个缓冲 append 时
            // writer 直接 fail。AVCaptureDevice.Format.audioChannelCount 不存在，
            // 从 formatDescription 的 ASBD 里读
            var micRate = 48_000
            var micChannels = 1
            if let device = AVCaptureDevice.default(for: .audio),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription) {
                // Format 没有 sampleRate 属性，一律从 ASBD 读
                micRate = max(1, Int(asbd.pointee.mSampleRate))
                micChannels = max(1, Int(asbd.pointee.mChannelsPerFrame))
            }
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: micRate,
                AVNumberOfChannelsKey: micChannels,
                AVEncoderBitRateKey: 128_000
            ])
            mic.expectsMediaDataInRealTime = true
            writer.add(mic)
            micInput = mic
        }

        let sink = RecorderStreamSink(
            onVideo: { [weak self] buffer in self?.appendVideo(buffer) },
            onAudio: { [weak self] buffer in self?.appendSystemAudio(buffer) },
            onStopped: { [weak self] error in Task { @MainActor in self?.streamDidStop(error) } }
        )
        self.sink = sink

        let stream = SCStream(filter: filter, configuration: conf, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: mediaQueue)
            if conf.capturesAudio {
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: mediaQueue)
            }
        } catch {
            lastError = TF("采集流启动失败：%@", error.localizedDescription)
            cleanup()
            return
        }
        self.stream = stream

        writer.startWriting()
        // 会话起点要等首个视频帧的时间戳（见 appendVideo），这里不能直接定 .zero
        sessionStarted = false
        guard writer.status == .writing else {
            let detail = writer.error?.localizedDescription
            lastError = detail.map { TF("录制引擎启动失败：%@", $0) } ?? T("录制引擎启动失败，请重试")
            // 失败时 AVAssetWriter 已经建了一个 0 字节的空壳，别留在录像目录里
            try? FileManager.default.removeItem(at: url)
            cleanup()
            return
        }

        stream.startCapture { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    Debug.log("recorder: startCapture failed \(error)")
                    self.lastError = error.localizedDescription
                    self.stop()
                    return
                }
                Debug.log("recorder: started \(source.kind.rawValue) \(conf.width)x\(conf.height) pip=\(self.pipCamera)")
                self.isRecording = true
                self.isPaused = false
                self.accumulated = 0
                self.segmentStart = Date()
                self.startTicker()
                self.preventSleep(true)
                self.statusNote = nil
                // 覆盖层与控制条都放到录制所在的那块屏上
                RecorderBar.targetScreen = self.targetScreen
                KeystrokeOverlayService.shared.targetScreen = self.targetScreen
                RecorderBar.shared.show()
                if micEnabled { self.startMicCapture() }
                if self.pipCamera { CameraBubble.shared.show(on: self.targetScreen) }
                if self.highlightClicks { ClickHighlightService.shared.start() }
                if self.showKeystrokes { KeystrokeOverlayService.shared.start() }
            }
        }
    }

    /// 停止；discard = 直接删掉这段（Recordly 的垃圾桶）
    func stop(discard: Bool = false) {
        guard writer != nil || stream != nil else { return }
        discardRequested = discard
        isRecording = false
        isPaused = false
        stopTicker()
        preventSleep(false)
        RecorderBar.shared.hide()
        // 关掉开关时才收气泡；开关还开着就留着预览，避免「开关是开的但气泡没了」
        if !pipCamera { CameraBubble.shared.hide() }
        statusNote = discard ? T("正在丢弃…") : T("正在保存…")

        stopMicCapture()
        ClickHighlightService.shared.stop()
        KeystrokeOverlayService.shared.stop()
        stream?.stopCapture { [weak self] _ in
            Task { @MainActor in self?.finishWriters() }
        }
        // stream 保留到 cleanup：removeStreamOutput 还需要它
    }

    /// 暂停：时间轴记下暂停点（之后的样本被裁掉），计时同步停走
    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            mediaQueue.async { [weak self] in self?.pauseTimeline.resume() }
            segmentStart = Date()
            isPaused = false
        } else {
            if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
            self.segmentStart = nil
            mediaQueue.async { [weak self] in self?.pauseTimeline.pause() }
            isPaused = true
            updateElapsed()
        }
    }

    private func streamDidStop(_ error: Error?) {
        if let error {
            Debug.log("recorder: stream stopped with error \(error)")
            lastError = error.localizedDescription
        } else {
            Debug.log("recorder: stream stopped")
        }
        finishWriters()
    }

    private func finishWriters() {
        guard !finishing else { return } // stopCapture 回调与 didStopWithError 可能都进来
        finishing = true
        guard let writer else { cleanup(); return }
        let url = movieURL
        let discard = discardRequested
        // markAsFinished / finishWriting 与采样追加同在 mediaQueue，避免跨线程竞争；
        // 先断开采样源，保证 markAsFinished 之后不再有任何 append
        mediaQueue.async { [weak self] in
            if let stream = self?.stream, let sink = self?.sink {
                try? stream.removeStreamOutput(sink, type: .screen)
                try? stream.removeStreamOutput(sink, type: .audio)
            }
            self?.videoInput?.markAsFinished()
            self?.audioInput?.markAsFinished()
            self?.micInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.cleanup()
                    if writer.status == .completed {
                        if discard, let url {
                            try? FileManager.default.removeItem(at: url)
                            self.statusNote = T("已丢弃这段录制")
                        } else {
                            self.lastMovieURL = url
                            if self.bezelRecording {
                                // 等带壳版本出来再提示，别一次性弹两条通知
                                self.statusNote = TF("已保存 %@，正在准备带壳版本…", url?.lastPathComponent ?? "")
                            } else {
                                self.statusNote = TF("已保存 %@", url?.lastPathComponent ?? "")
                                NotificationService.shared.notifyRecordingSaved(name: url?.lastPathComponent ?? "Aurora.mp4")
                            }
                            if let url, !discard { self.wrapIfNeeded(url) }
                        }
                    } else {
                        // 写盘失败：0 字节残片没有意义，直接清掉
                        if let url,
                           ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) == 0 {
                            try? FileManager.default.removeItem(at: url)
                        }
                        let reason = self.lastError ?? writer.error?.localizedDescription ?? T("录制文件写入失败")
                        Debug.log("recorder: frames appended=\(self.appendedVideoFrames)")
                        Debug.log("recorder: finish failed status=\(writer.status.rawValue) \(reason)")
                        self.lastError = reason
                        self.statusNote = nil
                        NotificationService.shared.notifyRecordingFailed(reason: reason)
                    }
                }
            }
        }
    }

    // MARK: - 带壳

    /// 当前会用的外壳：用户选定优先，否则按录制内容的宽高比 + 屏幕类型自动匹配
    var resolvedBezelFrame: DeviceFrame? {
        let service = ScreenshotService.shared
        if let bezelFrameID, let frame = service.frames.first(where: { $0.id == bezelFrameID }) {
            return frame
        }
        if let content = recordedContentSize, let matched = suggestedBezelFrame(for: content) {
            return matched
        }
        return service.defaultFrame
    }

    /// 给一段已有录像加壳（录制结束后自动调用，也可以在「最近录像」里手动点）。
    /// 返回错误文案，nil 表示成功；失败时原片一律保留。
    @discardableResult
    func wrapRecording(_ url: URL) async -> String? {
        guard !isWrappingBezel else { return T("正在处理另一段录像") }
        guard FileManager.default.fileExists(atPath: url.path) else { return T("找不到这段录像") }

        // 手动给旧录像加壳时没有「当前录制源」的上下文，直接按视频自己的比例挑
        let frame: DeviceFrame?
        if let bezelFrameID, let chosen = ScreenshotService.shared.frames.first(where: { $0.id == bezelFrameID }) {
            frame = chosen
        } else if let size = await Self.videoPixelSize(url), let matched = suggestedBezelFrame(for: size) {
            frame = matched
        } else {
            frame = ScreenshotService.shared.defaultFrame
        }
        guard let frame else { return T("没有可用的设备外壳") }

        let base = url.deletingPathExtension()
        let output = base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + " 带壳.mp4")

        isWrappingBezel = true
        bezelProgress = 0
        statusNote = T("正在套用设备外壳…")
        do {
            try await VideoBezel.wrap(source: url, frame: frame, to: output) { [weak self] value in
                self?.bezelProgress = value
            }
            isWrappingBezel = false
            lastMovieURL = output
            statusNote = TF("已保存 %@（原片保留）", output.lastPathComponent)
            NotificationService.shared.notifyRecordingSaved(name: output.lastPathComponent)
            return nil
        } catch {
            isWrappingBezel = false
            let reason = error.localizedDescription
            lastError = reason
            statusNote = TF("加壳失败，原片已保留：%@", url.lastPathComponent)
            return reason
        }
    }

    /// 视频旋转之后的像素尺寸（用来按比例匹配外壳）
    private static func videoPixelSize(_ url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// 录完之后按需套壳
    private func wrapIfNeeded(_ url: URL) {
        guard bezelRecording else { return }
        // 跨屏区域录制套进一台设备的壳里会张冠李戴，交给用户手动决定
        if bezelFrameID == nil, areaSpansDisplays {
            statusNote = T("跨屏区域录制没有加外壳")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let reason = await self.wrapRecording(url) {
                NotificationService.shared.notifyRecordingFailed(reason: reason)
                self.lastError = reason
            }
        }
    }

    private func cleanup() {
        if let stream, let sink {
            try? stream.removeStreamOutput(sink, type: .screen)
            try? stream.removeStreamOutput(sink, type: .audio)
        }
        stream = nil
        sink = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        movieURL = nil
        discardRequested = false
        finishing = false
        appendedVideoFrames = 0
        loggedWriterFailure = false
        sessionStarted = false
        mediaQueue.async { [weak self] in self?.pauseTimeline = RecorderPauseTimeline() }
    }

    // MARK: - 采样写入（mediaQueue 上调用；时间戳经暂停时间轴重映射）

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing else { return }
        guard let writer, let videoInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), writer.status == .writing else { return }
        let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // 首个视频帧到达时才建会话：把它当作时间轴零点，
        // 否则 PTS 带着开机时长，成片时长会离谱
        if !sessionStarted {
            writer.startSession(atSourceTime: source)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        guard let mapped = pauseTimeline.acceptVideoFrame(at: source) else { return }
        if mapped == source {
            videoInput.append(sampleBuffer)
        } else if let retimed = RecorderPauseTimeline.retimed(sampleBuffer, at: mapped) {
            videoInput.append(retimed)
        }
        appendedVideoFrames += 1
        if appendedVideoFrames == 1 || appendedVideoFrames % 300 == 0 {
            Debug.log("recorder: frames=\(appendedVideoFrames) writer=\(writer.status.rawValue) ready=\(videoInput.isReadyForMoreMediaData)")
        }
        if writer.status != .writing, !loggedWriterFailure {
            loggedWriterFailure = true
            if let error = writer.error as NSError? {
                Debug.log("recorder: writer failed \(error.domain) \(error.code) \(error.userInfo)")
            } else {
                Debug.log("recorder: writer failed \(writer.status.rawValue)")
            }
        }
    }

    private func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, sessionStarted else { return }
        guard let audioInput, let writer else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), writer.status == .writing else { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let mapped = pauseTimeline.outputTime(for: source) else { return }
        if mapped == source {
            audioInput.append(sampleBuffer)
        } else if let retimed = RecorderPauseTimeline.retimed(sampleBuffer, at: mapped) {
            audioInput.append(retimed)
        }
    }

    private func appendMic(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, sessionStarted else { return }
        guard let micInput, let writer else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), writer.status == .writing else { return }
        guard micInput.isReadyForMoreMediaData else { return }
        let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let mapped = pauseTimeline.outputTime(for: source) else { return }
        if mapped == source {
            micInput.append(sampleBuffer)
        } else if let retimed = RecorderPauseTimeline.retimed(sampleBuffer, at: mapped) {
            micInput.append(retimed)
        }
    }

    // MARK: - 麦克风采集（进同一个 mp4）

    private func startMicCapture() {
        guard micInput != nil, let device = AVCaptureDevice.default(for: .audio) else { return }
        let output = AVCaptureAudioDataOutput()
        let sink = RecorderMicSink { [weak self] buffer in
            // 麦克风缓冲统一转投 mediaQueue，与其它轨道的写入串行化
            self?.mediaQueue.async { self?.appendMic(buffer) }
        }
        output.setSampleBufferDelegate(sink, queue: micQueue)
        micSink = sink

        let session = AVCaptureSession()
        session.sessionPreset = .high
        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(deviceInput) { session.addInput(deviceInput) }
            if session.canAddOutput(output) { session.addOutput(output) }
        } catch {
            micSink = nil
            return
        }
        micSession = session
        session.startRunning()
    }

    private func stopMicCapture() {
        micSession?.stopRunning()
        micSession = nil
        micSink = nil
    }

    // MARK: - 计时 / 休眠

    private func updateElapsed() {
        var total = accumulated
        if let segmentStart { total += Date().timeIntervalSince(segmentStart) }
        let seconds = max(0, Int(total))
        elapsedText = String(format: "%d:%02d", seconds / 60, seconds % 60)
        RecorderBar.shared.update(text: elapsedText)
    }

    private func startTicker() {
        tick?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTicker() {
        tick?.invalidate()
        tick = nil
        accumulated = 0
        segmentStart = nil
        elapsedText = "0:00"
    }

    private func preventSleep(_ on: Bool) {
        if on, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Aurora screen recording"
            )
        } else if !on, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    nonisolated static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - SCStream 回调中转

private final class RecorderStreamSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let onVideo: (CMSampleBuffer) -> Void
    let onAudio: (CMSampleBuffer) -> Void
    let onStopped: (Error?) -> Void

    init(onVideo: @escaping (CMSampleBuffer) -> Void,
         onAudio: @escaping (CMSampleBuffer) -> Void,
         onStopped: @escaping (Error?) -> Void) {
        self.onVideo = onVideo
        self.onAudio = onAudio
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen: onVideo(sampleBuffer)
        case .audio: onAudio(sampleBuffer)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error)
    }
}

// MARK: - 麦克风回调

private final class RecorderMicSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let onBuffer: (CMSampleBuffer) -> Void

    init(onBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onBuffer(sampleBuffer)
    }
}
