import AVFoundation
import SwiftUI

struct RecordingFilmstrip: View {
    let movie: URL
    let map: RecordingEditMap
    let time: Double
    let selected: Double?
    let seek: (Double) -> Void
    let select: (RecordingClip, Double) -> Void
    let move: (RecordingClip, Int) -> Void
    @State private var insertion: Int?
    @State private var frames: [Double: CGImage] = [:]

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let scale = width / max(map.length, 0.001)
            VStack(spacing: 1) {
                // 标尺用于拖动播放头，片段轨道用于选择和移动。
                ZStack(alignment: .leading) {
                    Rectangle().fill(.secondary.opacity(0.1))
                    ForEach(0..<9) { i in
                        Rectangle().fill(.secondary.opacity(0.6)).frame(width: 1, height: 5)
                            .offset(x: CGFloat(i) * width / 8)
                    }
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                        .offset(x: max(0, min(width - 9, time * scale - 4.5)))
                }.frame(height: 14)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.15))
                    ForEach(map.clips) { clip in
                        let samples = sampleTimes(clip)
                        let w = max(0.1, clip.length * scale)
                        HStack(spacing: 0) {
                            ForEach(samples, id: \.self) { sample in
                                if let image = frames[sample] {
                                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                                        .frame(width: w / CGFloat(samples.count), height: 39).clipped()
                                } else { Color.secondary.opacity(0.16).frame(width: w / CGFloat(samples.count)) }
                            }
                        }.frame(width: w, height: 39).clipped()
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(selected == clip.id ? Color.accentColor : .secondary, lineWidth: selected == clip.id ? 3 : 1) }
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(TF("原片 %.2f 至 %.2f 秒", clip.id, clip.source.upperBound))
                        .accessibilityAddTraits(selected == clip.id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { select(clip, clip.start) }
                        .offset(x: clip.start * scale)
                    }
                    if map.clips.isEmpty { Text(T("时间线为空")).font(.caption).frame(maxWidth: .infinity) }
                    if let insertion {
                        let x = insertion < map.clips.count ? map.clips[insertion].start * scale : width
                        Rectangle().fill(Color.accentColor).frame(width: 4).offset(x: min(width - 4, x)).allowsHitTesting(false)
                    } else if !map.clips.isEmpty {
                        Rectangle().fill(.white).frame(width: 2).shadow(radius: 1)
                            .offset(x: min(width - 2, max(0, time * scale))).allowsHitTesting(false)
                    }
                }.frame(height: 39)
            }
            .overlay {
                RecordingClipTrackInput(map: map, seek: seek, select: select, move: move, insertion: $insertion)
                    .accessibilityHidden(true)
            }
        }.frame(height: 54)
        .help(T("点击片段选择，拖动片段排序，拖动标尺定位"))
        .task(id: map.spans) {
            let times = Set(map.clips.flatMap(sampleTimes))
            var next = frames.filter { times.contains($0.key) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 88)
            generator.requestedTimeToleranceAfter = .zero
            generator.requestedTimeToleranceBefore = .zero
            for t in times.sorted() where next[t] == nil {
                guard !Task.isCancelled else { return }
                next[t] = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 60_000)).image
            }
            if !Task.isCancelled { frames = next }
        }
    }

    private func sampleTimes(_ clip: RecordingClip) -> [Double] {
        let count = max(1, Int((9 * clip.length / max(map.length, 0.001)).rounded()))
        return (0..<count).map { clip.id + clip.length * (Double($0) + 0.5) / Double(count) }
    }

}
