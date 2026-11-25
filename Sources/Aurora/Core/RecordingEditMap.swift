import Foundation

/// 片段 ID 使用其原片入点。分割、删除、移动均不会复制原片时间区间。
struct RecordingClip: Identifiable, Equatable {
    let source: ClosedRange<Double>
    let start: Double // 成片时间
    var id: Double { source.lowerBound }
    var length: Double { source.upperBound - source.lowerBound }
    var end: Double { start + length }

    func intersection(with range: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lo = max(source.lowerBound, range.lowerBound), hi = min(source.upperBound, range.upperBound)
        guard lo < hi else { return nil }
        return (start + (lo - source.lowerBound))...(start + (hi - source.lowerBound))
    }
}

struct RecordingEditMap {
    let clips: [RecordingClip]
    var spans: [ClosedRange<Double>] { clips.map(\.source) }
    let length: Double
    private let order: [ClosedRange<Double>]

    init(_ appearance: RecordingAppearance, duration: Double) {
        let bounds = appearance.keptRange(duration: duration)
        var kept: [ClosedRange<Double>] = []
        var start = bounds.lowerBound
        for cut in (appearance.cuts ?? []).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard cut.upperBound > start, cut.lowerBound < bounds.upperBound else { continue }
            if start < cut.lowerBound { kept.append(start...cut.lowerBound) }
            start = max(start, cut.upperBound)
        }
        if start < bounds.upperBound { kept.append(start...bounds.upperBound) }
        order = appearance.clipOrder ?? [0...max(0, duration)]
        var result: [RecordingClip] = []
        var output = 0.0
        for raw in order {
            for span in kept {
                let lo = max(span.lowerBound, raw.lowerBound), hi = min(span.upperBound, raw.upperBound)
                guard lo < hi else { continue }
                result.append(.init(source: lo...hi, start: output))
                output += hi - lo
            }
        }
        clips = result
        length = output
    }

    func clip(at output: Double) -> RecordingClip? {
        let time = max(0, output.isFinite ? output : 0)
        return clips.first { time < $0.end - 1e-9 } ?? clips.last
    }

    func sourceTime(_ output: Double) -> Double {
        guard let c = clip(at: output) else { return 0 }
        return min(c.source.upperBound, c.id + max(0, output - c.start))
    }

    func outputTime(_ source: Double) -> Double {
        if let c = clips.first(where: { $0.id <= source && source < $0.source.upperBound }) {
            return c.start + (source - c.id)
        }
        if let c = clips.first(where: { $0.source.upperBound == source }) { return c.end }
        // 被裁去的时刻跳到原片中下一个可见帧。
        return clips.filter { $0.id > source }.min { $0.id < $1.id }?.start
            ?? clips.max { $0.source.upperBound < $1.source.upperBound }?.end ?? 0
    }

    func splitPoint(at output: Double, fps: Double) -> Double? {
        guard let c = clip(at: output), fps.isFinite, fps > 0 else { return nil }
        let point = (sourceTime(output) * fps).rounded() / fps
        let gap = 1 / fps - 1e-8
        guard point - c.id >= gap, c.source.upperBound - point >= gap else { return nil }
        return point
    }

    // 仅在可见边界切开底层顺序，恢复旧的裁剪或入出点时仍能找回隐藏画面。
    private func partition(at points: [Double]) -> [ClosedRange<Double>] {
        order.flatMap { raw in
            let edges = [raw.lowerBound] + Set(points.filter { raw.lowerBound < $0 && $0 < raw.upperBound }).sorted() + [raw.upperBound]
            return zip(edges, edges.dropFirst()).map { $0...$1 }
        }
    }

    func splitting(at source: Double) -> [ClosedRange<Double>] { partition(at: [source]) }

    func deleting(_ c: RecordingClip) -> [ClosedRange<Double>] {
        partition(at: [c.id, c.source.upperBound]).filter { $0 != c.source }
    }

    func moving(_ c: RecordingClip, to slot: Int) -> [ClosedRange<Double>]? {
        guard let index = clips.firstIndex(of: c), (0...clips.count).contains(slot),
              slot != index, slot != index + 1 else { return nil }
        let anchor = slot < clips.count ? clips[slot] : clips[clips.count - 1]
        var raw = partition(at: [c.id, c.source.upperBound, anchor.id, anchor.source.upperBound])
        raw.removeAll { $0 == c.source }
        guard let dest = raw.firstIndex(of: anchor.source) else { return nil }
        raw.insert(c.source, at: dest + (slot == clips.count ? 1 : 0))
        return raw
    }
}
