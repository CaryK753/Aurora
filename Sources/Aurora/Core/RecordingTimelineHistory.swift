import Foundation

/// 仅还原剪辑轨道。画面设置和缩放参数可以独立修改。
struct RecordingTimelineSnapshot: Equatable {
    let order: [ClosedRange<Double>]?
    let cuts: [ClosedRange<Double>]?
    let trimStart: Double?
    let trimEnd: Double?
    let selection: Double?
    let position: Double

    init(_ appearance: RecordingAppearance, selection: Double?, position: Double) {
        order = appearance.clipOrder
        cuts = appearance.cuts
        trimStart = appearance.trimStart
        trimEnd = appearance.trimEnd
        self.selection = selection
        self.position = position
    }

    func apply(to appearance: inout RecordingAppearance) {
        appearance.clipOrder = order
        appearance.trimStart = trimStart
        appearance.trimEnd = trimEnd
        appearance.cuts = cuts
    }
}

struct RecordingTimelineHistory {
    private(set) var past: [RecordingTimelineSnapshot] = []
    private(set) var future: [RecordingTimelineSnapshot] = []

    mutating func record(_ state: RecordingTimelineSnapshot) {
        past.append(state)
        if past.count > 100 { past.removeFirst() }
        future.removeAll()
    }

    mutating func undo(_ current: RecordingTimelineSnapshot) -> RecordingTimelineSnapshot? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(_ current: RecordingTimelineSnapshot) -> RecordingTimelineSnapshot? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}
