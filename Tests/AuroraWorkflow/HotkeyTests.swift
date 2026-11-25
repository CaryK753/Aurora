import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Aurora

@MainActor final class HotkeyTests: XCTestCase {
    func testOldPreferencesKeepBindingsAndAddUniqueDefaults() throws {
        let suite = UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let old: [String: HotkeyConfig] = [
            "panel": .captureShortcut(kVK_ANSI_W, "W"), "miniClipboard": .legacyMiniClipboard,
            "screenshot": .screenshotRegion, "recorder": .recorderToggle
        ]
        prefs.set(try JSONEncoder().encode(old), forKey: HotkeyService.storageKey)
        let service = HotkeyService(preferences: prefs)
        XCTAssertEqual(service.config(for: .panel), old["panel"])
        XCTAssertEqual(service.config(for: .miniClipboard), .miniClipboard)
        let actions = HotkeyService.Action.allCases
        XCTAssertEqual(Set(actions.map(\.hotKeyID)).count, actions.count)
        XCTAssertTrue(Set(actions.map(\.hotKeyID)).isDisjoint(with: [2, 3]))
        for action in actions where old[action.rawValue] == nil {
            XCTAssertEqual(service.config(for: action), action.defaultConfig)
        }
        for action in actions {
            XCTAssertFalse(actions.contains { $0 != action && $0.defaultConfig.matches(action.defaultConfig) })
        }
    }

    func testNativeRebindingPreservesWorkingKeyOnConflict() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1" else {
            throw XCTSkip("Requires a local window server for Carbon hotkeys")
        }
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let service = HotkeyService(preferences: prefs)
        func key(_ code: Int) -> HotkeyConfig {
            .init(keyCode: UInt32(code), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), display: "test-\(code)")
        }
        let first = key(kVK_F16), second = key(kVK_F17), external = key(kVK_F18)
        service.set(first, for: .recorderPause)
        service.set(second, for: .recorderBar)
        XCTAssertTrue(service.editErrors.isEmpty)
        service.set(second, for: .recorderPause)
        XCTAssertNotNil(service.editErrors[.recorderPause])
        XCTAssertEqual(service.config(for: .recorderPause), first)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x54455354, id: 42)
        XCTAssertEqual(RegisterEventHotKey(external.keyCode, external.modifiers, id,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref), noErr)
        defer { if let ref { UnregisterEventHotKey(ref) } }
        service.set(external, for: .recorderPause)
        XCTAssertNotNil(service.editErrors[.recorderPause])
        XCTAssertEqual(service.config(for: .recorderPause), first)
        var probe: EventHotKeyRef?
        XCTAssertNotEqual(RegisterEventHotKey(first.keyCode, first.modifiers, id,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &probe), noErr)
        if let probe { UnregisterEventHotKey(probe) }
        var triggered: [HotkeyService.Action] = []
        service.onAction = { triggered.append($0) }
        func send(_ action: HotkeyService.Action) async throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                       0, 0, &event), noErr)
            let hotkeyEvent = try XCTUnwrap(event)
            defer { ReleaseEvent(hotkeyEvent) }
            var keyID = EventHotKeyID(signature: 0x41555241, id: action.hotKeyID)
            XCTAssertEqual(SetEventParameter(hotkeyEvent, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &keyID), noErr)
            XCTAssertEqual(SendEventToEventTarget(hotkeyEvent, GetApplicationEventTarget()), noErr)
            await Task.yield()
        }
        let newActions: [HotkeyService.Action] = [.screenshotWindow, .screenshotFullscreen, .screenshotLong, .recorderPause, .recorderBar]
        for action in newActions { try await send(action) }
        XCTAssertEqual(triggered, newActions)
        service.startRecording(.recorderPause)
        try await send(.recorderBar)
        XCTAssertNil(service.recording)
        XCTAssertEqual(triggered, newActions)
        XCTAssertEqual(service.config(for: .recorderPause), first)
        let replacement = key(kVK_F19)
        service.set(replacement, for: .recorderPause)
        XCTAssertNil(service.editErrors[.recorderPause])
        XCTAssertEqual(HotkeyService(preferences: prefs).config(for: .recorderPause), replacement)
        probe = nil
        XCTAssertEqual(RegisterEventHotKey(first.keyCode, first.modifiers, id,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &probe), noErr)
        if let probe { UnregisterEventHotKey(probe) }
    }
}
