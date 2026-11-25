import AVKit
import Combine
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
        do {
            try Self.savePendingEdits()
            Self.window?.contentView = nil
            Self.window?.representedURL = nil
            Self.draft = nil
        } catch { NSAlert(error: error).runModal() }
    }
    private static var window: RecordingEditorWindow?

    static func open(_ url: URL, library: WallpaperLibrary) {
        let window = window ?? RecordingEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 620),
                                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if window.isVisible && window.representedURL == url { window.makeKeyAndOrderFront(nil); return }
        do { try savePendingEdits() } catch { NSAlert(error: error).runModal(); return }
        let draft = ZoomTimelineDraft(movie: url)
        self.draft = draft
        window.delegate = delegate
        window.title = T("录屏后期") + " · " + url.lastPathComponent
        window.representedURL = url
        window.contentView = NSHostingView(rootView: ZoomTimelineEditor(movie: url, draft: draft, wallpaperLibrary: library, editCommands: window.editCommands).id(UUID()))
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
        view.controlsStyle = .none
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
    let wallpaperLibrary: WallpaperLibrary
    let editCommands: PassthroughSubject<RecordingEditorWindow.EditCommand, Never>
    @State private var playing = false
    private var segments: [ZoomSegment] { draft.segments }
    @State private var selected: UUID?
    @State private var duration = 0.0
    @State private var ready: PreviewState?
    @State private var embeddedCursor = true
    private enum Inspector { case edit, zoom, appearance }
    @State private var inspector: Inspector = .edit
    @State private var selectedClip: Double?
    @State private var history = RecordingTimelineHistory()
    @State private var trimGesture = false
    @State private var trimRecorded = false
    @State private var cutMark: Double?
    @State private var fps = 30.0
    private var editMap: RecordingEditMap { RecordingEditMap(draft.appearance, duration: duration) }
    private var outputPosition: Double {
        let t = target ?? player.currentTime().seconds
        return t.isFinite ? min(editMap.length, max(0, t)) : 0
    }
    private var sourcePosition: Double { editMap.sourceTime(outputPosition) }
    @State private var note = ""
    @State private var target: Double?
    private var previewState: PreviewState { .init(duration: duration, segments: segments, appearance: draft.appearance) }
    @ObservedObject private var recorder = RecorderService.shared

    var body: some View {
        let map = editMap
        let zoomBars = zoomBars(in: map)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZoomPlayerView(player: player)
                    .frame(minWidth: 320, maxWidth: .infinity, minHeight: 190, maxHeight: .infinity)
                    .background(.black)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Picker(T("编辑工具"), selection: $inspector) {
                        Text(T("剪辑")).tag(Inspector.edit)
                        Text(T("缩放")).tag(Inspector.zoom)
                        Text(T("画面")).tag(Inspector.appearance)
                    }.pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 10)
                    if inspector == .appearance {
                        RecordingAppearanceView(appearance: $draft.appearance, library: wallpaperLibrary, hasTrace: !trace.points.isEmpty, embeddedCursor: embeddedCursor)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if inspector == .edit { editInspector } else { zoomInspector }
                            }.padding(12)
                        }
                    }
                }.frame(width: 315)
            }
            Divider()
            TimelineView(.animation(minimumInterval: 0.1, paused: !playing)) { _ in
                let time = target ?? player.currentTime().seconds
                let position = time.isFinite ? max(0, min(time, map.length)) : 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }.help(T("上一帧")).accessibilityLabel(T("上一帧"))
                            Button { togglePlayback() } label: { Image(systemName: player.rate == 0 ? "play.fill" : "pause.fill") }
                                .keyboardShortcut(.space, modifiers: []).accessibilityLabel(T("播放或暂停"))
                            Button { step(1) } label: { Image(systemName: "forward.frame.fill") }.help(T("下一帧")).accessibilityLabel(T("下一帧"))
                        }.disabled(ready != previewState || map.clips.isEmpty)
                        Text(seconds(position) + " / " + seconds(map.length)).font(.caption.monospacedDigit())
                        Divider().frame(height: 15)
                        Button { split() } label: { Label(T("分割"), systemImage: "scissors") }
                            .help(T("分割") + " (⌘B)")
                            .disabled(map.splitPoint(at: position, fps: fps) == nil)
                        Button { deleteClip() } label: { Label(T("删除片段"), systemImage: "trash") }
                            .help(T("删除片段") + " (Delete)").disabled(selectedClip == nil)
                        Spacer()
                        Button { restoreHistory(redo: false) } label: { Image(systemName: "arrow.uturn.backward") }
                            .help(T("撤销剪辑") + " (⌘Z)").accessibilityLabel(T("撤销剪辑")).disabled(history.past.isEmpty)
                        Button { restoreHistory(redo: true) } label: { Image(systemName: "arrow.uturn.forward") }
                            .help(T("重做剪辑") + " (⇧⌘Z)").accessibilityLabel(T("重做剪辑")).disabled(history.future.isEmpty)
                    }.buttonStyle(.borderless)
                    RecordingFilmstrip(movie: movie, map: map, time: position, selected: selectedClip,
                        seek: { player.pause(); seekOutput($0) }, select: { clip, pos in
                            selectedClip = clip.id
                            player.pause()
                            seekOutput(pos)
                        }, move: moveClip)
                    if !segments.isEmpty && map.length > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.secondary.opacity(0.12))
                                ForEach(zoomBars) { bar in
                                    Button {
                                        inspector = .zoom
                                        selected = bar.id.segment
                                        player.pause()
                                        seekOutput((bar.range.lowerBound + bar.range.upperBound) / 2)
                                    } label: {
                                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(selected == bar.id.segment ? 1 : 0.45))
                                    }.buttonStyle(.plain)
                                    .frame(width: max(1, geo.size.width * (bar.range.upperBound - bar.range.lowerBound) / map.length))
                                    .offset(x: geo.size.width * bar.range.lowerBound / map.length)
                                    .accessibilityLabel(seconds(bar.range.lowerBound) + " – " + seconds(bar.range.upperBound))
                                }
                            }
                        }.frame(height: 14)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            HStack {
                Text(draft.saveError.map { TF("时间线未保存：%@", $0) } ?? note).font(.caption).textSelection(.enabled)
                Spacer()
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
                }.disabled(editMap.clips.isEmpty || ready != previewState || recorder.exportingZoom != nil || (segments.isEmpty && !draft.appearance.needsRendering))
                    .buttonStyle(.borderedProminent)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(minWidth: 680, minHeight: 450)
        .disabled(recorder.exportingZoom != nil)
        .task {
            do {
                let asset = AVURLAsset(url: movie)
                let length = try await asset.load(.duration).seconds
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let rate = try await track.load(.nominalFrameRate)
                    if rate > 0 { fps = Double(rate) }
                }
                guard length.isFinite, length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let pointer = try await Task.detached { try RecordingPointerData.load(from: movie) }.value
                trace = RecordingZoom(points: pointer.points)
                embeddedCursor = pointer.embeddedCursor
                let saved = try await Task.detached { try ZoomTimelineDraft.readDocument(for: movie, duration: length) }.value
                try Task.checkCancellation()
                draft.restore(saved?.segments ?? ZoomSegment.automatic(trace, duration: length), appearance: saved?.appearance ?? .init())
                selected = segments.first?.id
                duration = length
                selectedClip = editMap.clips.first?.id
            } catch { note = error.localizedDescription }
        }
        .task(id: previewState) {
            guard duration > 0 else { return }
            let snapshot = previewState, path = trace
            guard !editMap.clips.isEmpty else {
                player.pause()
                player.replaceCurrentItem(with: nil)
                ready = nil
                target = nil
                return
            }
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
                let pos = outputPosition
                target = nil
                player.pause()
                player.replaceCurrentItem(with: item)
                ready = snapshot
                seekOutput(pos)
            } catch { if !Task.isCancelled { note = error.localizedDescription } }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { playing = $0 == .playing }
        .onReceive(editCommands) { command in
            guard duration > 0, recorder.exportingZoom == nil else { return }
            switch command {
            case .split: split()
            case .delete: deleteClip()
            case .undo: restoreHistory(redo: false)
            case .redo: restoreHistory(redo: true)
            }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
            if let window = event.object as? NSWindow, window.title == T("录屏后期") + " · " + movie.lastPathComponent { player.pause() }
        }
    }

    @ViewBuilder private var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(T("缩放片段"), selection: Binding(get: { selected }, set: { id in
                if let s = segments.first(where: { $0.id == id }) { select(s) }
            })) {
                if segments.isEmpty { Text("—").tag(nil as UUID?) }
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, s in
                    Text("\(index + 1) · " + seconds(s.start) + " – " + seconds(s.end)).tag(Optional(s.id))
                }
            }
            HStack {
                Button(T("在播放处添加")) { add() }.disabled(editMap.clips.isEmpty)
                Button(T("删除")) {
                    draft.segments.removeAll { $0.id == selected }
                    selected = segments.first?.id
                }.disabled(selected == nil)
            }
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
    }

    @ViewBuilder private var editInspector: some View {
        let bounds = draft.appearance.keptRange(duration: duration)
        let map = editMap
        if !map.clips.isEmpty {
            Picker(T("片段"), selection: Binding(get: { selectedClip }, set: { id in
                if let clip = map.clips.first(where: { $0.id == id }) {
                    selectedClip = id
                    player.pause()
                    seekOutput(clip.start)
                }
            })) {
                ForEach(Array(map.clips.enumerated()), id: \.element.id) { index, clip in
                    Text("\(index + 1) · " + seconds(clip.id) + " – " + seconds(clip.source.upperBound)).tag(Optional(clip.id))
                }
            }
            if let index = map.clips.firstIndex(where: { $0.id == selectedClip }) {
                HStack {
                    Button(T("左移片段")) { moveClip(map.clips[index], to: index - 1) }.disabled(index == 0)
                    Button(T("右移片段")) { moveClip(map.clips[index], to: index + 2) }.disabled(index + 1 == map.clips.count)
                }
            }
            Divider()
        }
        Text(T("原片保留范围")).font(.headline)
        control(T("入点"), Binding(get: { bounds.lowerBound }, set: { setTrim(true, $0) }), 0, max(0, bounds.upperBound - 1 / fps), "s", trackTrim: true)
        control(T("出点"), Binding(get: { bounds.upperBound }, set: { setTrim(false, $0) }),
                min(duration, bounds.lowerBound + 1 / fps), duration, "s", trackTrim: true)
        HStack {
            Button(T("在此设入点")) { setTrim(true, sourcePosition) }.keyboardShortcut("i", modifiers: [])
            Button(T("在此设出点")) { setTrim(false, sourcePosition) }.keyboardShortcut("o", modifiers: [])
        }
        Divider()
        Text(T("移除片段")).font(.headline)
        if let cutMark {
            Text(T("片段起点") + "  " + seconds(cutMark)).font(.caption.monospacedDigit())
            HStack {
                Button(T("移除到播放头")) {
                    let end = outputPosition
                    guard abs(end - cutMark) >= 1 / fps else { note = T("请先将播放头移到另一帧"); return }
                    let cut = min(end, cutMark)...max(end, cutMark)
                    var next = draft.appearance
                    let removed = editMap.clips.compactMap { clip -> ClosedRange<Double>? in
                        let lo = max(clip.start, cut.lowerBound), hi = min(clip.end, cut.upperBound)
                        guard lo < hi else { return nil }
                        return (clip.id + (lo - clip.start))...(clip.id + (hi - clip.start))
                    }
                    next.cuts = (next.cuts ?? []) + removed
                    guard RecordingEditMap(next, duration: duration).length >= 1 / fps else { note = T("至少保留一帧"); return }
                    applyEdit(next, position: cut.lowerBound)
                    self.cutMark = nil
                }
                Button(T("取消")) { self.cutMark = nil }
            }
        } else {
            Button(T("在播放头标记起点")) { player.pause(); cutMark = outputPosition }.disabled(map.clips.isEmpty)
        }
        ForEach(Array((draft.appearance.cuts ?? []).enumerated()), id: \.offset) { index, cut in
            HStack {
                Text(seconds(cut.lowerBound) + " – " + seconds(cut.upperBound)).font(.caption.monospacedDigit())
                Spacer()
                Button(T("恢复片段")) {
                    var next = draft.appearance
                    next.cuts?.remove(at: index)
                    applyEdit(next, position: RecordingEditMap(next, duration: duration).outputTime(cut.lowerBound))
                }
            }
        }
        Divider()
        Toggle(T("成片静音"), isOn: Binding(get: { draft.appearance.mute == true }, set: { draft.appearance.mute = $0 ? true : nil }))
        Button(T("重置裁剪")) {
            var next = draft.appearance
            next.trimStart = nil; next.trimEnd = nil; next.cuts = nil
            next.clipOrder = nil
            applyEdit(next, position: sourcePosition)
            cutMark = nil
        }.disabled(draft.appearance.clipOrder == nil && draft.appearance.trimStart == nil && draft.appearance.trimEnd == nil && draft.appearance.cuts?.isEmpty != false)
    }

    private func setTrim(_ start: Bool, _ value: Double) {
        guard duration > 0 else { return }
        let range = draft.appearance.keptRange(duration: duration)
        let gap = min(duration, 1 / fps)
        var next = draft.appearance
        if start {
            let inPoint = max(0, min(range.upperBound - gap, value))
            next.trimStart = inPoint == 0 ? nil : inPoint
        } else {
            let outPoint = min(duration, max(range.lowerBound + gap, value))
            next.trimEnd = outPoint == duration ? nil : outPoint
        }
        guard RecordingEditMap(next, duration: duration).length >= gap - 0.000001 else { note = T("至少保留一帧"); return }
        guard next != draft.appearance else { return }
        let map = RecordingEditMap(next, duration: duration)
        let point = start ? next.trimStart ?? 0 : max(0, (next.trimEnd ?? duration) - gap)
        applyEdit(next, position: map.outputTime(point))
    }

    private var snapshot: RecordingTimelineSnapshot {
        .init(draft.appearance, selection: selectedClip, position: outputPosition)
    }

    private func applyEdit(_ next: RecordingAppearance, position: Double, selection: Double? = nil) {
        guard next != draft.appearance else { return }
        if !trimGesture || !trimRecorded { history.record(snapshot) }
        if trimGesture { trimRecorded = true }
        installEdit(next, position: position, selection: selection)
    }

    private func installEdit(_ next: RecordingAppearance, position: Double, selection: Double?) {
        player.pause()
        cutMark = nil
        let map = RecordingEditMap(next, duration: duration)
        let pos = min(map.length, max(0, position))
        selectedClip = map.clips.first { $0.id == selection }?.id ?? map.clip(at: pos)?.id
        draft.appearance = next
        seekOutput(pos)
    }

    private func restoreHistory(redo: Bool) {
        let current = snapshot
        guard let state = redo ? history.redo(current) : history.undo(current) else { return }
        var next = draft.appearance
        state.apply(to: &next)
        installEdit(next, position: state.position, selection: state.selection)
    }

    private func split() {
        let map = editMap
        guard let point = map.splitPoint(at: outputPosition, fps: fps) else { return }
        var next = draft.appearance
        next.clipOrder = map.splitting(at: point)
        applyEdit(next, position: map.outputTime(point), selection: point)
    }

    private func deleteClip() {
        let map = editMap
        guard let clip = map.clips.first(where: { $0.id == selectedClip }) else { return }
        let pos = outputPosition
        var next = draft.appearance
        next.clipOrder = map.deleting(clip)
        applyEdit(next, position: pos <= clip.start ? pos : max(clip.start, pos - clip.length))
    }

    private func moveClip(_ clip: RecordingClip, to slot: Int) {
        guard let order = editMap.moving(clip, to: slot) else { return }
        var next = draft.appearance
        next.clipOrder = order
        let source = sourcePosition
        let pos = RecordingEditMap(next, duration: duration).outputTime(clip.source.contains(source) && source < clip.source.upperBound ? source : clip.id)
        applyEdit(next, position: pos, selection: clip.id)
    }

    private func step(_ frames: Int) {
        player.pause()
        seekOutput(outputPosition + Double(frames) / fps)
    }

    private func togglePlayback() {
        if player.rate != 0 { player.pause(); return }
        if player.currentTime().seconds >= editMap.length - 0.001 { player.seek(to: .zero) }
        player.play()
    }

    private struct ZoomBar: Identifiable {
        struct ID: Hashable {
            let clip: Double
            let segment: UUID
        }
        let id: ID
        let range: ClosedRange<Double>
    }

    private func zoomBars(in map: RecordingEditMap) -> [ZoomBar] {
        var bars: [ZoomBar] = []
        for clip in map.clips {
            var low = 0, high = segments.count
            while low < high {
                let mid = (low + high) / 2
                if segments[mid].end <= clip.id { low = mid + 1 } else { high = mid }
            }
            for s in segments[low...] {
                if s.start >= clip.source.upperBound { break }
                if let range = clip.intersection(with: s.start...s.end) {
                    bars.append(.init(id: .init(clip: clip.id, segment: s.id), range: range))
                }
            }
        }
        return bars
    }

    private struct PreviewState: Equatable {
        let duration: Double
        let segments: [ZoomSegment]
        let appearance: RecordingAppearance
    }

    private func seconds(_ v: Double) -> String { String(format: "%.2f s", v) }

    private func control(_ name: String, _ value: Binding<Double>, _ low: Double, _ high: Double, _ unit: String, trackTrim: Bool = false) -> some View {
        HStack {
            Text(name).frame(width: 65, alignment: .leading)
            Slider(value: value, in: low...max(low + 0.000001, high), onEditingChanged: { active in
                if trackTrim { trimGesture = active; trimRecorded = false }
            }).disabled(high <= low)
            TextField(name, value: Binding(get: { value.wrappedValue }, set: { v in
                if v.isFinite { value.wrappedValue = max(low, min(high, v)) }
            }), format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 65)
            Text(unit).frame(width: 14)
        }
    }

    @State private var seekGeneration = 0

    private func seekOutput(_ time: Double) {
        let position = min(editMap.length, max(0, time))
        target = position
        seekGeneration += 1
        let generation = seekGeneration
        guard ready == previewState, player.currentItem != nil else { return }
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                if generation == seekGeneration { target = nil }
            }
        }
    }

    private func select(_ s: ZoomSegment) {
        selected = s.id
        player.pause()
        seekOutput(editMap.outputTime((s.start + s.end) / 2))
    }

    private func add() {
        let time = sourcePosition
        let end = min(duration, time + 2, segments.first(where: { $0.start > time })?.start ?? duration)
        guard time.isFinite, end - time >= 0.05, !segments.contains(where: { $0.start <= time && time < $0.end }) else {
            note = T("请将播放头移到空白时段")
            return
        }
        let s = ZoomSegment(start: time, end: end, center: CGPoint(x: 0.5, y: 0.5), follows: false)
        draft.segments = (segments + [s]).sorted { $0.start < $1.start }
        selected = s.id
        seekOutput(editMap.outputTime((time + end) / 2))
        note = ""
    }
}
