import XCTest
@testable import LogitechPlugin

final class LogitechButtonPolicyTests: XCTestCase {
    func testBluetoothStandardButtonsRemainNative() {
        XCTAssertEqual(LogitechButtonPolicy.nativeButton(cid: 0x52, transport: "Bluetooth Low Energy"), 2)
        XCTAssertEqual(LogitechButtonPolicy.nativeButton(cid: 0x53, transport: "Bluetooth"), 3)
        XCTAssertEqual(LogitechButtonPolicy.nativeButton(cid: 0x56, transport: "Bluetooth"), 4)
    }
    @MainActor
    func testNoLogitechMouseDisablesPluginDespiteSavedPreference() {
        let suite = "aurora.logitech.availability." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "logitech.enabled")
        let service = LogitechDeviceService(defaults: defaults, autoConnect: false, availabilityProvider: { false })
        XCTAssertFalse(service.isAvailable)
        XCTAssertFalse(service.isEnabled)
        service.setEnabled(true)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.handleNativeButton(3))
    }
    func testSpecialAndReceiverButtonsUseHIDPP() {
        for cid: UInt16 in [0x50, 0x51, 0xC4, 0xD7] {
            XCTAssertNil(LogitechButtonPolicy.nativeButton(cid: cid, transport: "Bluetooth Low Energy"))
        }
        XCTAssertNil(LogitechButtonPolicy.nativeButton(cid: 0x53, transport: "USB"))
    }
}
