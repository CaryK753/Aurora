import AVFoundation
import AppKit
import XCTest
@testable import Aurora

@MainActor final class RecordingClipTests: XCTestCase {
    func testOrderHistoryAndLegacyHiddenMaterial() throws {
        var appearance = RecordingAppearance()
        appearance.trimStart = 1
        appearance.cuts = [3...4]
        let a = RecordingEditMap(appearance, duration: 8)
        XCTAssertEqual(a.spans, [1...3, 4...8])
        XCTAssertNil(a.splitPoint(at: 2, fps: 30))
        let point = try XCTUnwrap(a.splitPoint(at: 3.007, fps: 30))
        XCTAssertEqual(point, 5)
        appearance.clipOrder = a.splitting(at: point)
        let b = RecordingEditMap(appearance, duration: 8)
        var history = RecordingTimelineHistory()
        let before = RecordingTimelineSnapshot(appearance, selection: 5, position: 3)
        history.record(before)
        appearance.clipOrder = try XCTUnwrap(b.moving(b.clips[2], to: 0))
        let c = RecordingEditMap(appearance, duration: 8)
        XCTAssertEqual(c.spans, [5...8, 1...3, 4...5])
        XCTAssertEqual(c.clip(at: 3)?.id, 1)
        XCTAssertEqual(c.sourceTime(0.5), 5.5)
        XCTAssertEqual(c.outputTime(2.5), 4.5)
        XCTAssertEqual(c.clips.compactMap { $0.intersection(with: 2...6) }, [0...1, 4...5, 5...6])
        let after = RecordingTimelineSnapshot(appearance, selection: 5, position: 0)
        XCTAssertEqual(history.undo(after), before)
        XCTAssertEqual(history.redo(before), after)
        XCTAssertEqual(history.undo(after), before)
        history.record(before)
        XCTAssertTrue(history.future.isEmpty)
        appearance.clipOrder = c.deleting(c.clips[1])
        appearance.cuts = nil
        appearance.trimStart = nil
        XCTAssertEqual(RecordingEditMap(appearance, duration: 8).spans, [0...1, 5...8, 3...5])
        let movie = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: ZoomTimelineDraft.file(for: movie)) }
        let draft = ZoomTimelineDraft(movie: movie)
        draft.restore([])
        draft.appearance = appearance
        try draft.flush()
        XCTAssertEqual(try ZoomTimelineDraft.readDocument(for: movie, duration: 8)?.appearance, appearance)
        appearance.clipOrder = []
        XCTAssertNil(RecordingEditMap(appearance, duration: 8).clip(at: 0))
        draft.appearance = appearance
        try draft.flush()
        XCTAssertEqual(try ZoomTimelineDraft.readDocument(for: movie, duration: 8)?.appearance?.clipOrder, [])
    }

    /// 三段不同底色、不同音高的原片在横向 1/4 处有一条白线。
    func testReorderedMP4KeepsVideoCursorZoomAndAudioTogether() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "clip-colors", withExtension: "mp4"))
        let movie = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: fixture, to: movie)
        defer { try? FileManager.default.removeItem(at: movie) }
        var appearance = RecordingAppearance()
        appearance.clipOrder = [2...3, 0...1]
        appearance.cursor = .dot
        appearance.cursorTint = .orange
        appearance.cursorSize = 2
        appearance.cursorEffect = .ripple
        let trace = RecordingZoom(points: [
            .init(time: 0, x: 0.8, y: 0.5, click: false),
            .init(time: 1, x: 0.8, y: 0.5, click: false),
            .init(time: 2, x: 0.3, y: 0.5, click: false),
            .init(time: 2.4, x: 0.3, y: 0.5, click: true)
        ])
        let zoom = ZoomSegment(start: 2, end: 3, center: .init(x: 0.25, y: 0.5), scale: 2, follows: false)
        let preview = try await RecordingFinish.make(movie: movie, segments: [zoom], trace: trace, appearance: appearance, frame: nil)
        let url = try await RecordingZoom.export(movie, asset: preview.asset, composition: preview.composition, finished: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let length = try await asset.load(.duration)
        XCTAssertEqual(length.seconds, 2, accuracy: 0.035)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero
        for (time, blue, marker, cursor, frequency) in [(0.45, true, 170, 192, 880.0), (1.45, false, 86, 256, 440.0)] {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let bitmap = NSBitmapImageRep(cgImage: image)
            func color(_ x: Int, _ y: Int) throws -> NSColor {
                try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            }
            let background = try color(30, 30)
            XCTAssertEqual(background.blueComponent > 0.7, blue)
            XCTAssertEqual(background.redComponent > 0.7, !blue)
            let stripe = try color(marker, 50)
            XCTAssertGreaterThan(min(stripe.redComponent, stripe.greenComponent, stripe.blueComponent), 0.8)
            let dot = try color(cursor, 90)
            XCTAssertGreaterThan(dot.redComponent, 0.7)
            XCTAssertLessThan(dot.greenComponent, 0.65)
            XCTAssertGreaterThan(dot.greenComponent, 0.25)
            if blue {
                // 点击后外圈出现在实心光标范围外。
                let halo = try (cursor + 9...cursor + 16).map { try color($0, 90) }
                XCTAssertTrue(halo.contains { $0.redComponent > 0.38 && $0.greenComponent > 0.13 })
            }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 5))
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(audio.first), outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var previous: Int16 = 0, crossings = 0, count = 0
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                let size = CMBlockBufferGetDataLength(block)
                var values = [Int16](repeating: 0, count: size / 2)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, noErr)
                for value in values {
                    if previous < 0 && value >= 0 { crossings += 1 }
                    previous = value
                }
                count += values.count
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThan(count, 8000)
            XCTAssertEqual(Double(crossings) * 48000 / Double(max(1, count)), frequency, accuracy: 7)
        }
    }
}
