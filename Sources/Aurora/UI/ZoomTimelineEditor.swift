import AVKit
import SwiftUI

@MainActor
final class ZoomTimelineWindow: NSObject, NSWindowDelegate {
    private static let delegate = ZoomTimelineWindow()
    private static var draft: ZoomTimelineDraft?

    static func savePendingEdits() throws {
        window?.makeFirstResponder(nil)
        try draft?.flush()
    }

    func windowWillClose(_ notification: Notification) {
        do { try Self.savePendingEdits() } catch { NSAlert(error: error).runModal() }
    }
    private static var window: NSWindow?

    static func open(_ url: URL) {
        let window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650),
                                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if window.isVisible && window.representedURL == url { window.makeKeyAndOrderFront(nil); return }
        do { try savePendingEdits() } catch { NSAlert(error: error).runModal(); return }
        let draft = ZoomTimelineDraft(movie: url)
        self.draft = draft
        window.delegate = delegate
        window.title = T("缩放时间线") + " · " + url.lastPathComponent
        window.representedURL = url
        window.contentView = NSHostingView(rootView: ZoomTimelineEditor(movie: url, draft: draft).id(UUID()))
        if !window.isVisible { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ZoomPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct ZoomTimelineEditor: View {
    let movie: URL
    @State private var player = AVPlayer()
    @State private var trace = RecordingZoom(points: [])
    @ObservedObject var draft: ZoomTimelineDraft
    private var segments: [ZoomSegment] { draft.segments }
    @State private var selected: UUID?
    @State private var duration = 0.0
    @State private var ready: PreviewState?
    @State private var embeddedCursor = true
    @State private var showAppearance = false
    @State private var note = ""
    @State private var target: Double?
    private var previewState: PreviewState { .init(duration: duration, segments: segments, appearance: draft.appearance) }
    @ObservedObject private var recorder = RecorderService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZoomPlayerView(player: player).frame(minHeight: 140)
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let time = player.currentTime().seconds
                HStack {
                    Text(seconds(time.isFinite ? time : 0)).monospacedDigit()
                    Slider(value: Binding(get: { time.isFinite ? min(max(0, time), duration) : 0 },
                                          set: { player.pause(); seek($0) }), in: 0...max(0.001, duration))
                        .accessibilityLabel(T("播放位置"))
                    Text(seconds(duration)).monospacedDigit()
                }.font(.caption)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.12))
                    ForEach(segments) { s in
                        Button {
                            select(s)
                        } label: {
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(selected == s.id ? 1 : 0.45))
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(2, geo.size.width * (s.end - s.start) / max(duration, 0.001)))
                        .offset(x: geo.size.width * s.start / max(duration, 0.001))
                        .accessibilityLabel(seconds(s.start) + " – " + seconds(s.end))
                    }
                }
            }.frame(height: 24)
            HStack {
                Picker(T("缩放片段"), selection: Binding(get: { selected }, set: { id in
                    if let s = segments.first(where: { $0.id == id }) { select(s) }
                })) {
                    if segments.isEmpty { Text("—").tag(nil as UUID?) }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, s in
                        Text("\(index + 1) · " + seconds(s.start) + " – " + seconds(s.end)).tag(Optional(s.id))
                    }
                }
                Button(T("在播放处添加")) { add() }
                Button(T("删除")) {
                    draft.segments.removeAll { $0.id == selected }
                    selected = segments.first?.id
                }.disabled(selected == nil)
            }
            if let i = segments.firstIndex(where: { $0.id == selected }) {
                let s = segments[i]
                let gap = min(0.05, s.end - s.start)
                control(T("起点"), $draft.segments[i].start, i > 0 ? segments[i-1].end : 0, s.end - gap, "s")
                control(T("终点"), $draft.segments[i].end, s.start + gap, i + 1 < segments.count ? segments[i+1].start : duration, "s")
                control(T("倍率"), $draft.segments[i].scale, 1, 4, "×")
                Toggle(T("跟随鼠标"), isOn: $draft.segments[i].follows).disabled(trace.points.isEmpty)
                if !s.follows {
                    control(T("水平位置"), Binding(get: { Double(s.center.x) }, set: { draft.segments[i].center.x = CGFloat($0) }), 0, 1, "")
                    control(T("垂直位置"), Binding(get: { Double(s.center.y) }, set: { draft.segments[i].center.y = CGFloat($0) }), 0, 1, "")
                }
            }
            HStack {
                Text(draft.saveError.map { TF("时间线未保存：%@", $0) } ?? note).font(.caption).textSelection(.enabled)
                Spacer()
                Button(T("画面设置")) { showAppearance.toggle() }
                    .disabled(duration <= 0)
                    .popover(isPresented: $showAppearance) {
                        RecordingAppearanceView(appearance: $draft.appearance, hasTrace: !trace.points.isEmpty,
                                                embeddedCursor: embeddedCursor)
                    }
                Button(T("确认并导出")) {
                    guard let item = player.currentItem, let composition = item.videoComposition else { return }
                    player.pause()
                    Task {
                        if let error = await recorder.exportZoom(movie, asset: item.asset, composition: composition, finished: draft.appearance.needsRendering) { note = error }
                        else if let output = recorder.lastMovieURL {
                            note = TF("已保存 %@", output.lastPathComponent)
                            NSWorkspace.shared.activateFileViewerSelecting([output])
                        }
                    }
                }.disabled(ready != previewState || recorder.exportingZoom != nil || (segments.isEmpty && !draft.appearance.needsRendering))
            }
        }
        .padding().frame(minWidth: 450, minHeight: 450)
        .disabled(recorder.exportingZoom != nil)
        .task {
            do {
                let asset = AVURLAsset(url: movie)
                let length = try await asset.load(.duration).seconds
                guard length.isFinite, length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let pointer = try await Task.detached { try RecordingPointerData.load(from: movie) }.value
                trace = RecordingZoom(points: pointer.points)
                embeddedCursor = pointer.embeddedCursor
                let saved = try await Task.detached { try ZoomTimelineDraft.readDocument(for: movie, duration: length) }.value
                try Task.checkCancellation()
                draft.restore(saved?.segments ?? ZoomSegment.automatic(trace, duration: length), appearance: saved?.appearance ?? .init())
                selected = segments.first?.id
                duration = length
            } catch { note = error.localizedDescription }
        }
        .task(id: previewState) {
            guard duration > 0 else { return }
            let snapshot = previewState, path = trace
            do {
                try await Task.sleep(for: .milliseconds(80))
                let appearance = snapshot.appearance
                let frame = ScreenshotService.shared.frames.first { $0.id == appearance.frameID }
                let preview = try await RecordingFinish.make(movie: movie, segments: snapshot.segments, trace: path,
                                                             appearance: appearance, frame: frame)
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: preview.asset)
                item.videoComposition = preview.composition
                note = ""
                var pos = target ?? player.currentTime().seconds
                if !pos.isFinite { pos = 0 }
                if ready != nil, let s = segments.first(where: { $0.id == selected }), pos <= s.start || pos >= s.end {
                    pos = (s.start + s.end) / 2
                }
                target = nil
                player.pause()
                player.replaceCurrentItem(with: item)
                seek(pos)
                ready = snapshot
            } catch { if !Task.isCancelled { note = error.localizedDescription } }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
            if let window = event.object as? NSWindow, window.title == T("缩放时间线") + " · " + movie.lastPathComponent { player.pause() }
        }
    }

    private struct PreviewState: Equatable {
        let duration: Double
        let segments: [ZoomSegment]
        let appearance: RecordingAppearance
    }

    private func seconds(_ v: Double) -> String { String(format: "%.2f s", v) }

    private func control(_ name: String, _ value: Binding<Double>, _ low: Double, _ high: Double, _ unit: String) -> some View {
        HStack {
            Text(name).frame(width: 65, alignment: .leading)
            Slider(value: value, in: low...max(low + 0.000001, high)).disabled(high <= low)
            TextField(name, value: Binding(get: { value.wrappedValue }, set: { v in
                if v.isFinite { value.wrappedValue = max(low, min(high, v)) }
            }), format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 65)
            Text(unit).frame(width: 14)
        }
    }

    private func seek(_ time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func select(_ s: ZoomSegment) {
        selected = s.id
        player.pause()
        seek((s.start + s.end) / 2)
    }

    private func add() {
        let time = max(0, player.currentTime().seconds)
        let end = min(duration, time + 2, segments.first(where: { $0.start > time })?.start ?? duration)
        guard time.isFinite, end - time >= 0.05, !segments.contains(where: { $0.start <= time && time < $0.end }) else {
            note = T("请将播放头移到空白时段")
            return
        }
        let s = ZoomSegment(start: time, end: end, center: CGPoint(x: 0.5, y: 0.5), follows: false)
        draft.segments = (segments + [s]).sorted { $0.start < $1.start }
        selected = s.id
        target = (time + end) / 2
        note = ""
    }
}
