import Foundation

struct RecordingAppearance: Codable, Equatable, Sendable {
    enum Cursor: String, Codable, CaseIterable, Sendable {
        case none, arrow, dot, ring, image
    }

    enum CursorTint: String, Codable, CaseIterable, Sendable {
        case white, black, blue, orange
    }

    var backdrop: URL?
    var solidBackdrop = false
    var frameID: String?
    var cursor: Cursor = .none
    var cursorTint: CursorTint = .white
    var cursorSize = 1.0
    var cursorImage: URL?

    var hasBackdrop: Bool { solidBackdrop || backdrop != nil }
    var needsRendering: Bool { hasBackdrop || frameID != nil || cursor != .none }
}
