import Foundation

struct RecordingAppearance: Codable, Equatable, Sendable {
    enum Cursor: String, Codable, CaseIterable, Sendable {
        case none, arrow, dot, ring, crosshair, diamond, beam, image
    }

    enum CursorEffect: String, Codable, CaseIterable, Sendable { case ripple, trail }

    enum CursorTint: String, Codable, CaseIterable, Sendable {
        case white, black, blue, orange
    }

    var wallpaper: WallpaperItem?
    var cursorEffect: CursorEffect?
    var clipOrder: [ClosedRange<Double>]?
    var cuts: [ClosedRange<Double>]?
    var trimStart: Double?
    var trimEnd: Double?
    var mute: Bool?

    func keptRange(duration: Double) -> ClosedRange<Double> {
        let end = max(0, min(duration, trimEnd ?? duration))
        let start = max(0, min(end, trimStart ?? 0))
        return start...end
    }

    var backdrop: URL?
    var solidBackdrop = false
    var frameID: String?
    var cursor: Cursor = .none
    var cursorTint: CursorTint = .white
    var cursorSize = 1.0
    var cursorImage: URL?

    var hasBackdrop: Bool { solidBackdrop || backdrop != nil || wallpaper != nil }
    var needsRendering: Bool { clipOrder != nil || hasBackdrop || frameID != nil || cursor != .none || trimStart != nil || trimEnd != nil || mute == true || cuts?.isEmpty == false }
}
