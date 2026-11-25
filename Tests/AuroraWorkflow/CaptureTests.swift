import CoreImage
import XCTest
@testable import Aurora

final class CaptureTests: XCTestCase {
    func testSquareDragOnWideCanvasStopsAtImageEdge() {
        let end = CanvasMouseNSView.squareEnd(from: CGPoint(x: 0.5, y: 0.75),
                                              toward: CGPoint(x: 1, y: 1),
                                              size: CGSize(width: 400, height: 200))
        XCTAssertEqual(end, CGPoint(x: 0.625, y: 1))
    }

    func testZoomFollowsClicksAndReturnsToFullFrame() {
        let zoom = RecordingZoom(points: [
            ZoomPoint(time: 1, x: 0, y: 1, click: true),
            ZoomPoint(time: 1.3, x: 0.5, y: 0.5, click: false),
            ZoomPoint(time: 1.5, x: 1, y: 0, click: false)
        ])
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(zoom.crop(at: 0.9, extent: frame, magnification: 2), frame)
        XCTAssertEqual(zoom.crop(at: 1.6, extent: frame, magnification: 2),
                       CGRect(x: 100, y: 0, width: 100, height: 50))
        XCTAssertGreaterThan(zoom.crop(at: 2.8, extent: frame, magnification: 2).width, 100)
        XCTAssertEqual(zoom.crop(at: 3, extent: frame, magnification: 2), frame)
    }

    func testBlurProducesOpaqueIntermediatePixelAtHardEdge() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                          bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(ctx.makeImage())
        let blurred = try XCTUnwrap(ScreenshotEditorView.gaussianBlur(image, radius: 8))
        ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let edge = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)[16 * 256 + 32 * 4]
        XCTAssertGreaterThan(edge, 20)
        XCTAssertLessThan(edge, 240)
    }
}
