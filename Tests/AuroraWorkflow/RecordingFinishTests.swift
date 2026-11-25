import AppKit
import AVFoundation
import ImageIO
import XCTest
@testable import Aurora

@MainActor
final class RecordingFinishTests: XCTestCase {
    func testOpeningUsesTopLeftCoordinatesAndIgnoresOuterTransparency() throws {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8,
                                             bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.4, alpha: 1))
        canvas.fill(CGRect(x: 5, y: 5, width: 190, height: 110))
        canvas.clear(CGRect(x: 20, y: 40, width: 160, height: 62))
        let frame = try XCTUnwrap(canvas.makeImage())
        XCTAssertEqual(ImportedDeviceFrames.screenOpening(frame), CGRect(x: 20, y: 18, width: 160, height: 62))
    }

    func testBackdropAndCursorPersistWithExistingDraftFormat() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("recording.mp4")
        try Data(#"{"version":1,"segments":[]}"#.utf8).write(to: ZoomTimelineDraft.file(for: movie))
        let legacy = try XCTUnwrap(ZoomTimelineDraft.readDocument(for: movie, duration: 2))
        XCTAssertNil(legacy.appearance)
        let draft = ZoomTimelineDraft(movie: movie)
        draft.restore(legacy.segments)
        draft.appearance.backdrop = root.appendingPathComponent("dynamic.mov")
        draft.appearance.cursor = .ring
        draft.appearance.cursorSize = 1.75
        draft.appearance.cursorTint = .blue
        draft.appearance.frameID = "macbook-pro-14-silver"
        try draft.flush()
        XCTAssertEqual(try ZoomTimelineDraft.readDocument(for: movie, duration: 2)?.appearance, draft.appearance)
    }

    func testCursorStopsAtBoundaryAndReturns() {
        var trace = RecordingZoomTrace()
        trace.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        trace.origin = .zero
        trace.sample(CGPoint(x: 40, y: 30), at: CMTime(seconds: 0.1, preferredTimescale: 1000), click: false)
        trace.sample(CGPoint(x: -1, y: 30), at: CMTime(seconds: 0.2, preferredTimescale: 1000), click: false)
        trace.sample(CGPoint(x: 40, y: 30), at: CMTime(seconds: 0.4, preferredTimescale: 1000), click: false)
        let zoom = RecordingZoom(points: trace.points)
        XCTAssertNil(zoom.cursor(at: 0))
        XCTAssertEqual(zoom.cursor(at: 0.19), CGPoint(x: 0.4, y: 0.7))
        XCTAssertNil(zoom.cursor(at: 0.25))
        XCTAssertEqual(zoom.cursor(at: 0.4), CGPoint(x: 0.4, y: 0.7))
    }

    func testAppleFramePNGCompatibility() throws {
        guard let root = ProcessInfo.processInfo.environment["AURORA_FRAME_FIXTURES"] else {
            throw XCTSkip("Set AURORA_FRAME_FIXTURES to local product frame PNG fixtures")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let hole = try XCTUnwrap(ImportedDeviceFrames.screenOpening(image), file.lastPathComponent)
            XCTAssertGreaterThan(hole.width, Double(image.width) * 0.5, file.lastPathComponent)
            XCTAssertGreaterThan(hole.height, Double(image.height) * 0.4, file.lastPathComponent)
            print("Detected opening: \(file.lastPathComponent) \(hole)")
        }
    }

    func testDynamicBackdropAndFullExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["AURORA_FINISH_FIXTURE"] else {
            throw XCTSkip("Set AURORA_FINISH_FIXTURE to the directory with source.mp4 and backdrop.mp4")
        }
        let root = URL(fileURLWithPath: path)
        let movie = root.appendingPathComponent("source.mp4")
        let trace = RecordingZoom(points: [ZoomPoint(time: 0.1, x: 0.5, y: 0.5, click: true)])
        let frame = try XCTUnwrap(ScreenshotService.shared.frames.first { $0.id == "macbook-pro-14-silver" })
        let appearance = RecordingAppearance(backdrop: root.appendingPathComponent("backdrop.mp4"), frameID: frame.id,
                                             cursor: .dot, cursorTint: .orange, cursorSize: 2)
        let preview = try await RecordingFinish.make(movie: movie, segments: ZoomSegment.automatic(trace, duration: 2),
                                                     trace: trace, appearance: appearance, frame: frame)
        let generator = AVAssetImageGenerator(asset: preview.asset)
        generator.videoComposition = preview.composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let late = try await generator.image(at: CMTime(seconds: 0.9, preferredTimescale: 600)).image
        let loop = try await generator.image(at: CMTime(seconds: 1.1, preferredTimescale: 600)).image
        let colors = try [early, late, loop].map { image in
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        }
        XCTAssertGreaterThan(colors[0].redComponent, 0.7)
        XCTAssertGreaterThan(colors[1].blueComponent, 0.7)
        XCTAssertGreaterThan(colors[2].redComponent, 0.7)
        let center = try XCTUnwrap(NSBitmapImageRep(cgImage: late).colorAt(x: 320, y: 180)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(center.redComponent, 0.8)
        XCTAssertLessThan(center.blueComponent, 0.25)
        let output = try await RecordingZoom.export(movie, asset: preview.asset, composition: preview.composition, finished: true)
        let exported = AVURLAsset(url: output)
        let tracks = try await exported.loadTracks(withMediaType: .audio)
        let duration = try await exported.load(.duration)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.08)
        let playback = AVAssetImageGenerator(asset: exported)
        playback.requestedTimeToleranceBefore = .zero
        playback.requestedTimeToleranceAfter = .zero
        let decoded = try await playback.image(at: CMTime(seconds: 0.9, preferredTimescale: 600)).image
        let bitmap = NSBitmapImageRep(cgImage: decoded)
        let previewBitmap = NSBitmapImageRep(cgImage: late)
        for point in [(4, 4), (320, 180), (200, 170)] {
            let actual = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
            let expected = try XCTUnwrap(previewBitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.15)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.15)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.15)
        }
        print("Finished export: \(output.path)")
    }
}
