import AppKit
import ScreenCaptureKit
import AVFoundation
import XCTest
@testable import Aurora

@MainActor
final class RecorderInputTests: XCTestCase {
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTFail("Timed out waiting for recorder", file: file, line: line)
        throw CocoaError(.coderInvalidValue)
    }

    func testUSBDeviceUnavailable() async {
        let capture = USBDeviceRecording { _, _ in XCTFail("An unavailable input did not start") }
        let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            try await capture.start(id: "aurora-test-missing-device", url: path)
            XCTFail("An unavailable device should fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }

    func testAreaShowsAuroraWindowBehindExcludedControls() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1",
              CGPreflightScreenCaptureAccess() else { throw XCTSkip("Requires local screen recording permission") }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let center = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY + 40)
        let rect = CGRect(x: center.x - 110, y: center.y - 22, width: 220, height: 44)
        let window = NSWindow(contentRect: rect.insetBy(dx: -20, dy: -10), styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .magenta
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let service = RecorderService.shared
        let prefs = (service.countdown, service.includeAurora, service.selectedSourceID, service.systemAudio)
        defer {
            service.countdown = prefs.0
            service.includeAurora = prefs.1
            service.selectedSourceID = prefs.2
            service.systemAudio = prefs.3
        }
        let displays = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
        service.commitArea(rect, displays: displays)
        service.systemAudio = false
        service.countdown = 0
        for include in [true, false] {
            service.includeAurora = include
            let previous = service.lastMovieURL
            service.start()
            try await waitUntil { !service.isStarting }
            XCTAssertTrue(service.isRecording, service.lastError ?? "")
            try await Task.sleep(for: .milliseconds(650))
            service.stop()
            try await waitUntil { !service.isStopping }
            let movie = try XCTUnwrap(service.lastMovieURL, service.lastError ?? "")
            XCTAssertNotEqual(movie, previous)
            defer { try? FileManager.default.removeItem(at: movie) }
            let image = try await AVAssetImageGenerator(asset: AVURLAsset(url: movie)).image(at: .zero).image
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.3, include)
        }
    }

    func testRecordAuroraPanelAfterCountdown() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1",
              CGPreflightScreenCaptureAccess() else { throw XCTSkip("Requires local screen recording permission") }
        _ = NSApplication.shared
        let panel = AuroraPanel(contentRect: CGRect(x: 140, y: 140, width: 240, height: 140), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.backgroundColor = .magenta
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let service = RecorderService.shared
        let previous = (service.includeAurora, service.countdown, service.selectedSourceID)
        defer {
            service.includeAurora = previous.0
            service.countdown = previous.1
            service.selectedSourceID = previous.2
            RecorderBar.shared.hide()
        }
        try await Task.sleep(for: .milliseconds(400))
        let id = "window:" + String(panel.windowNumber)
        service.includeAurora = true
        try await waitUntil { service.sources.contains { $0.id == id } }
        service.includeAurora = false
        try await waitUntil { !service.sources.contains { $0.id == id } }
        service.includeAurora = true
        try await waitUntil { service.sources.contains { $0.id == id } }
        service.selectedSourceID = id
        let beforeStart = service.lastMovieURL
        service.countdown = 3
        service.start()
        try await waitUntil { service.remaining > 0 }
        service.toggle()
        try await waitUntil { !service.isStarting }
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.lastMovieURL, beforeStart)
        service.start()
        try await waitUntil { service.remaining > 0 }
        XCTAssertFalse(service.isRecording)
        try await waitUntil { !service.isStarting }
        XCTAssertTrue(service.isRecording, service.lastError ?? "")
        try await Task.sleep(for: .milliseconds(500))
        panel.backgroundColor = .systemGreen
        try await Task.sleep(for: .milliseconds(500))
        service.stop()
        try await waitUntil { !service.isStopping }
        let movie = try XCTUnwrap(service.lastMovieURL, service.lastError ?? "")
        defer { try? FileManager.default.removeItem(at: movie) }
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThan(duration, 3)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertGreaterThan(color.blueComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.3)
    }
}
