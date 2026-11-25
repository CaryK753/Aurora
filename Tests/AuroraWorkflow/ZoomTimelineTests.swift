import AppKit
import CoreMedia
import ImageIO
import XCTest
@testable import Aurora

final class ZoomTimelineTests: XCTestCase {
    func testEditedSegmentsControlTimeFocusAndScale() {
        let trace = RecordingZoom(points: [ZoomPoint(time: 1, x: 0, y: 1, click: true),
                                           ZoomPoint(time: 1.5, x: 0, y: 1, click: true),
                                           ZoomPoint(time: 4, x: 1, y: 0, click: true)])
        var edits = ZoomSegment.automatic(trace, duration: 5)
        XCTAssertEqual(edits.map(\.end), [3.5, 5])
        edits[0].start = 1.5
        edits[0].end = 3
        edits[0].scale = 4
        edits[0].center = CGPoint(x: 0.25, y: 0.75)
        edits[0].follows = false
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(ZoomSegment.crop(edits, trace: trace, at: 1.4, extent: frame), frame)
        XCTAssertEqual(ZoomSegment.crop(edits, trace: trace, at: 2, extent: frame),
                       CGRect(x: 50, y: 125, width: 100, height: 50))
        XCTAssertEqual(ZoomSegment.crop(edits, trace: trace, at: 3.1, extent: frame), frame)
        XCTAssertEqual(ZoomSegment.virtualFrame(screen: CGRect(x: -80, y: 300, width: 100, height: 100),
                                                content: CGRect(x: 0, y: 0, width: 50, height: 50), pixelScale: 2,
                                                output: CGSize(width: 200, height: 100)),
                       CGRect(x: -80, y: 300, width: 200, height: 100))
    }

    @MainActor
    func testExistingImageCanBeImportedAndFramed() throws {
        let frame = try XCTUnwrap(ScreenshotService.shared.defaultFrame)
        let source = try XCTUnwrap(ScreenshotService.resourceURL(frame.id + ".png"))
        let image = try XCTUnwrap(ScreenshotService.importImage(source))
        let result = try XCTUnwrap(ScreenshotService.compose(image: image, frame: frame))
        XCTAssertEqual(result.width, frame.pixelWidth)
        XCTAssertEqual(result.height, frame.pixelHeight)
    }

    @MainActor
    func testSmallImportedImageOpensFrameChooser() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1" else {
            throw XCTSkip("Requires a local window server")
        }
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                              bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let window = EditorWindow(image: try XCTUnwrap(context.makeImage()), chooseFrame: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<30 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertGreaterThanOrEqual(window.frame.width, 480)
    }

    @MainActor
    func testOptionalOwnWindowCapture() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1",
              CGPreflightScreenCaptureAccess() else { throw XCTSkip("Requires a local window server and screen permission") }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20, width: 220, height: 130)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .magenta
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(350))
        let id = CGWindowID(window.windowNumber)
        let before = (await ScreenshotService.selectableWindows(includeAurora: true)).first { $0.id == id }!.frame
        let moved = CGRect(x: frame.minX + 40, y: frame.minY + 25, width: 260, height: 140)
        window.setFrame(moved, display: true)
        try await Task.sleep(for: .milliseconds(100))
        let after = (await ScreenshotService.selectableWindows(includeAurora: true)).first { $0.id == id }!.frame
        XCTAssertEqual(after.minX - before.minX, 40, accuracy: 1)
        XCTAssertEqual(after.size, moved.size)
        var trace = RecordingZoomTrace()
        trace.origin = .zero
        trace.bounds = ZoomSegment.virtualFrame(screen: after, content: CGRect(origin: .zero, size: after.size),
                                                    pixelScale: 1, output: CGSize(width: 280, height: 140))
        trace.sample(CGPoint(x: after.midX, y: after.midY), at: CMTime(value: 1, timescale: 1), click: true)
        XCTAssertEqual(try XCTUnwrap(trace.points.first).x, 130.0 / 280, accuracy: 0.001)
        XCTAssertEqual(trace.points.first?.y, 0.5)
        let visible = await ScreenshotService.selectableWindows(includeAurora: true)
        let hidden = await ScreenshotService.selectableWindows(includeAurora: false)
        XCTAssertTrue(visible.contains { $0.id == id })
        XCTAssertFalse(hidden.contains { $0.id == id })
        let rect = CGRect(x: frame.midX, y: frame.midY, width: 2, height: 2)
        for include in [true, false] {
            let captured = await ScreenshotService.capture(rect: rect, includeAurora: include)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(captured))
            let color = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.4, include)
        }
    }
}
