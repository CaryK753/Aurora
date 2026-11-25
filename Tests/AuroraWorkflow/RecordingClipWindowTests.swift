import AppKit
import XCTest
@testable import Aurora

@MainActor final class RecordingClipWindowTests: XCTestCase {
    func testDragSplitDeleteUndoRedoAndReopen() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1" else {
            throw XCTSkip("Requires local editor window")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let movie = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "clip-colors", withExtension: "mp4"))
        try FileManager.default.copyItem(at: fixture, to: movie)
        defer {
            try? FileManager.default.removeItem(at: movie)
            try? FileManager.default.removeItem(at: ZoomTimelineDraft.file(for: movie))
        }
        let library = WallpaperLibrary(scanSystem: false)
        ZoomTimelineWindow.open(movie, library: library)
        let window = try XCTUnwrap(app.windows.first { $0.representedURL == movie })
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(e, key as CFString, &value)
            return value
        }
        func find(_ label: String, _ e: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
            guard depth < 22 else { return nil }
            if [kAXDescriptionAttribute, kAXTitleAttribute].contains(where: { attribute(e, $0) as? String == label }) { return e }
            for child in attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let found = find(label, child, depth + 1) { return found }
            }
            return nil
        }
        let root = AXUIElementCreateApplication(getpid())
        func press(_ label: String) async throws {
            let element = try XCTUnwrap(find(T(label), root), label)
            XCTAssertEqual((attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue, true, label)
            XCTAssertEqual(AXUIElementPerformAction(element, kAXPressAction as CFString), .success, label)
            try await Task.sleep(for: .milliseconds(200))
        }
        func key(_ text: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            try await Task.sleep(for: .milliseconds(250))
        }
        func order() throws -> [ClosedRange<Double>]? {
            try ZoomTimelineWindow.savePendingEdits()
            return try ZoomTimelineDraft.readDocument(for: movie, duration: 3)?.appearance?.clipOrder
        }
        let track = try XCTUnwrap(find(TF("原片 %.2f 至 %.2f 秒", 0.0, 3.0), root))
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(try XCTUnwrap(attribute(track, kAXPositionAttribute)) as! AXValue, .cgPoint, &origin)
        AXValueGetValue(try XCTUnwrap(attribute(track, kAXSizeAttribute)) as! AXValue, .cgSize, &size)
        func mouse(_ type: NSEvent.EventType, _ fraction: Double) async throws {
            let point = CGPoint(x: origin.x + size.width * fraction, y: NSScreen.screens[0].frame.maxY - origin.y - size.height / 2)
            let local = window.convertPoint(fromScreen: point)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            app.sendEvent(event)
            try await Task.sleep(for: .milliseconds(120))
        }
        XCTAssertGreaterThan(size.width, 300)
        try await mouse(.leftMouseDown, 1.0 / 3)
        try await mouse(.leftMouseUp, 1.0 / 3)
        try await key("b", 11, .command)
        let split = try XCTUnwrap(order())
        XCTAssertEqual(split.count, 2)
        let second = try XCTUnwrap(split.last)
        XCTAssertEqual(second.lowerBound, 1, accuracy: 0.04)
        try await mouse(.leftMouseDown, 0.65)
        try await mouse(.leftMouseDragged, 0.4)
        try await mouse(.leftMouseDragged, 0.05)
        try await mouse(.leftMouseUp, 0.05)
        XCTAssertEqual(try order(), Array(split.reversed()))
        try await press("删除片段")
        XCTAssertEqual(try order(), [split[0]])
        try await press("撤销剪辑")
        XCTAssertEqual(try order(), Array(split.reversed()))
        try await key("Z", 6, [.command, .shift])
        XCTAssertEqual(try order(), [split[0]])
        try await key("z", 6, .command)
        window.close()
        ZoomTimelineWindow.open(movie, library: library)
        try await Task.sleep(for: .milliseconds(450))
        try await key("\u{7F}", 51, [])
        XCTAssertEqual(try order(), [split[0]], "重开后首段应为移动过的第二段")
        try await press("删除片段")
        XCTAssertEqual(try order(), [])
        let export = try XCTUnwrap(find(T("确认并导出"), root))
        XCTAssertEqual((attribute(export, kAXEnabledAttribute) as? NSNumber)?.boolValue, false)
        try await press("撤销剪辑")
        XCTAssertEqual(try order(), [split[0]])
    }
}
