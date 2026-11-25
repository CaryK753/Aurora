import Foundation
import XCTest
@testable import Aurora

@MainActor
final class ZoomDraftTests: XCTestCase {
    private func movie() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("录制.mp4")
    }

    func testImmediateCloseRestoresEveryFieldAndAnEmptyEditOverridesClicks() throws {
        let url = try movie()
        let clip = ZoomSegment(start: 1, end: 2, center: CGPoint(x: 0.15, y: 0.85))
        let session = ZoomTimelineDraft(movie: url)
        session.restore([clip])
        try session.flush()
        XCTAssertNil(try ZoomTimelineDraft.read(for: url, duration: 5))
        var changed = clip
        changed.start = 0.3
        changed.end = 2.45
        changed.center = CGPoint(x: 0.73, y: 0.18)
        changed.scale = 3.25
        changed.follows = false
        session.segments = [changed, ZoomSegment(start: 3, end: 4.7, center: .zero)]
        try session.flush()
        let recovered = try XCTUnwrap(ZoomTimelineDraft.read(for: url, duration: 5))
        XCTAssertEqual(recovered, session.segments)
        let next = ZoomTimelineDraft(movie: url)
        next.restore(recovered)
        next.segments.removeAll()
        try next.flush()
        XCTAssertEqual(try ZoomTimelineDraft.read(for: url, duration: 5), [])
    }

    func testEditsAutosaveWhileWindowIsOpen() async throws {
        let url = try movie()
        let session = ZoomTimelineDraft(movie: url)
        session.restore([])
        session.segments = [ZoomSegment(start: 0, end: 1, center: .zero)]
        session.segments[0].scale = 3
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if try ZoomTimelineDraft.read(for: url, duration: 1) == session.segments { return }
        }
        XCTFail("Latest edit was not written")
    }

    func testReadFailurePreservesDocumentAndSeparateRecordingsDoNotShareDrafts() throws {
        let url = try movie()
        let file = ZoomTimelineDraft.file(for: url)
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try ZoomTimelineDraft.read(for: url, duration: 2))
        try ZoomTimelineDraft(movie: url).flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
        XCTAssertNil(try ZoomTimelineDraft.read(for: url.appendingPathExtension("mov"), duration: 2))
    }
}
