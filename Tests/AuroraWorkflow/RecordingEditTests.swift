import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import Aurora

@MainActor final class RecordingEditTests: XCTestCase {
    func testEditMapKeepsSourceTimeAcrossOverlappingCuts() throws {
        var appearance = RecordingAppearance()
        appearance.trimStart = 1
        appearance.trimEnd = 7
        appearance.cuts = [2...3, 2.5...4, 5...6, 8...10]
        let map = RecordingEditMap(appearance, duration: 8)
        XCTAssertEqual(map.spans, [1...2, 4...5, 6...7])
        XCTAssertEqual(map.length, 3)
        XCTAssertEqual(map.sourceTime(1), 4)
        XCTAssertEqual(map.outputTime(3), 1)
        XCTAssertEqual(map.outputTime(6.2), 2.2, accuracy: 0.001)
        XCTAssertEqual(map.sourceTime(5), 7)
        let old = try JSONDecoder().decode(RecordingAppearance.self, from: Data(#"{"cursor":"arrow","cursorSize":1,"cursorTint":"white","solidBackdrop":false}"#.utf8))
        XCTAssertEqual(RecordingEditMap(old, duration: 8).spans, [0...8])
        let movie = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: ZoomTimelineDraft.file(for: movie)) }
        appearance.cursor = .crosshair
        appearance.cursorEffect = .trail
        appearance.cursorSize = 2.45
        appearance.wallpaper = WallpaperLibrary.proceduralPresets.first
        let draft = ZoomTimelineDraft(movie: movie)
        draft.restore([])
        draft.appearance = appearance
        try draft.flush()
        XCTAssertEqual(try ZoomTimelineDraft.readDocument(for: movie, duration: 8)?.appearance, appearance)
    }

    func testTrimmedExportUsesOriginalCursorTimeAndMutesSound() async throws {
        guard let path = ProcessInfo.processInfo.environment["AURORA_FINISH_FIXTURE"] else { throw XCTSkip("Requires movie fixture") }
        let movie = URL(fileURLWithPath: path).appendingPathComponent("source.mp4")
        var appearance = RecordingAppearance()
        appearance.trimStart = 0.15
        appearance.trimEnd = 1.85
        appearance.cuts = [0.5...1.1]
        appearance.mute = true
        appearance.cursor = .diamond
        appearance.cursorEffect = .ripple
        appearance.cursorTint = .orange
        appearance.cursorSize = 3
        appearance.wallpaper = WallpaperLibrary.proceduralPresets[1]
        let trace = RecordingZoom(points: [.init(time: 0, x: 0.2, y: 0.5, click: false),
                                           .init(time: 1.1, x: 0.8, y: 0.5, click: true)])
        let preview = try await RecordingFinish.make(movie: movie, segments: [], trace: trace, appearance: appearance, frame: nil)
        let file = try await RecordingZoom.export(movie, asset: preview.asset, composition: preview.composition, finished: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = AVURLAsset(url: file)
        let length = try await output.load(.duration).seconds
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(length, 1.1, accuracy: 0.07)
        XCTAssertTrue(audio.isEmpty)
        let generator = AVAssetImageGenerator(asset: output)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero
        for (time, x) in [(0.1, 0.2), (0.55, 0.8)] {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let bitmap = NSBitmapImageRep(cgImage: image)
            let px = Int(Double(image.width) * (0.08 + 0.84 * x))
            let y = image.height / 2
            let colors = (-20...20).compactMap { bitmap.colorAt(x: px + $0, y: y)?.usingColorSpace(.sRGB) }
            XCTAssertTrue(colors.contains { $0.redComponent > 0.7 && $0.greenComponent < 0.65 && $0.blueComponent < 0.25 })
        }
        appearance.mute = nil
        let audible = try await RecordingFinish.make(movie: movie, segments: [], trace: trace, appearance: appearance, frame: nil)
        let tracks = try await audible.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let audioSpan = try await XCTUnwrap(tracks.first).load(.timeRange)
        XCTAssertEqual(audioSpan.duration.seconds, 1.1, accuracy: 0.07)
    }
}

extension RecordingEditTests {
    func testWallpaperAnimationSupportsSeekingAndGIFLoop() async throws {
        let size = CGSize(width: 196, height: 104)
        let box = CGRect(origin: .zero, size: size)
        let context = CIContext()
        for item in WallpaperLibrary.proceduralPresets {
            let animation = try XCTUnwrap(try RecordingAnimatedBackdrop(url: nil, wallpaper: item, canvas: size))
            func sample(_ seconds: Double) async throws -> Data {
                let frame = try await animation.image(at: seconds)
                let pixels = try XCTUnwrap(context.createCGImage(frame, from: box))
                return try XCTUnwrap(pixels.dataProvider?.data) as Data
            }
            let original = try await sample(0)
            let later = try await sample(3)
            let back = try await sample(0)
            XCTAssertNotEqual(original, later, item.id)
            XCTAssertEqual(original, back, item.id)
        }
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: file) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        for (color, delay) in [(CIColor.red, 0.2), (.blue, 0.5)] {
            let image = try XCTUnwrap(context.createCGImage(CIImage(color: color).cropped(to: box), from: box))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let gif = try XCTUnwrap(try RecordingAnimatedBackdrop(url: file, wallpaper: nil, canvas: size))
        for (time, red) in [(0.1, true), (0.56, false), (0.8, true)] {
            let image = try await gif.image(at: time)
            let pixel = try XCTUnwrap(context.createCGImage(image, from: box))
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: pixel).colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent > 0.8, red)
            XCTAssertEqual(color.blueComponent > 0.8, !red)
        }
    }
}

extension RecordingEditTests {
    func testCursorEffectsAndScaleChangeRenderedPixels() throws {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 200)
        let screen = CIImage(color: .black).cropped(to: canvas)
        let context = CIContext()
        let trace = RecordingZoom(points: [
            .init(time: 0, x: 0.25, y: 0.5, click: false),
            .init(time: 0.2, x: 0.5, y: 0.5, click: true),
            .init(time: 0.4, x: 0.75, y: 0.5, click: false)
        ])
        func coverage(_ appearance: RecordingAppearance) throws -> Int {
            let layers = try RecordingFinishLayers(canvas: canvas, frame: nil, appearance: appearance, still: nil)
            let frame = layers.render(screen: screen, background: nil, time: 0.35, segments: [], trace: trace)
            var pixels = [UInt8](repeating: 0, count: 400 * 200 * 4)
            context.render(frame, toBitmap: &pixels, rowBytes: 1600, bounds: canvas, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 20 ? 1 : 0) }
        }
        for cursor in [RecordingAppearance.Cursor.crosshair, .diamond, .beam] {
            var appearance = RecordingAppearance()
            appearance.cursor = cursor
            let small = try coverage(appearance)
            appearance.cursorSize = 2.5
            let large = try coverage(appearance)
            XCTAssertGreaterThan(small, 0)
            XCTAssertGreaterThan(large, small)
            appearance.cursorEffect = .ripple
            XCTAssertGreaterThan(try coverage(appearance), large)
            appearance.cursorEffect = .trail
            XCTAssertGreaterThan(try coverage(appearance), large)
        }
    }
}

extension RecordingEditTests {
    func testEditorRestoresMuteAfterImmediateClose() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1",
              let path = ProcessInfo.processInfo.environment["AURORA_FINISH_FIXTURE"] else {
            throw XCTSkip("Requires local editor UI and movie fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let movie = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path).appendingPathComponent("source.mp4"), to: movie)
        defer {
            try? FileManager.default.removeItem(at: movie)
            try? FileManager.default.removeItem(at: ZoomTimelineDraft.file(for: movie))
        }
        let library = WallpaperLibrary(scanSystem: false)
        func checkbox(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 22 else { return nil }
            for key in [kAXDescriptionAttribute, kAXTitleAttribute] {
                var label: CFTypeRef?
                AXUIElementCopyAttributeValue(element, key as CFString, &label)
                if label as? String == T("成片静音") { return element }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in children as? [AXUIElement] ?? [] {
                if let found = checkbox(child, depth: depth + 1) { return found }
            }
            return nil
        }
        for reopen in [false, true] {
            ZoomTimelineWindow.open(movie, library: library)
            let window = try XCTUnwrap(app.windows.first { $0.representedURL == movie })
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(700))
            let toggle = try XCTUnwrap(checkbox(AXUIElementCreateApplication(getpid())))
            if reopen {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(toggle, kAXValueAttribute as CFString, &value)
                XCTAssertEqual((value as? NSNumber)?.boolValue, true)
            } else {
                XCTAssertEqual(AXUIElementPerformAction(toggle, kAXPressAction as CFString), .success)
            }
        }
        XCTAssertEqual(try ZoomTimelineDraft.readDocument(for: movie, duration: 2)?.appearance?.mute, true)
    }
}
