import XCTest
@testable import LogitechPlugin

final class LogitechButtonPolicyTests: XCTestCase {
    func testBluetoothStandardButtonsRemainNative() {
        XCTAssertEqual(LogitechButtonPolicy.nativeButton(cid: 0x52, transport: "Bluetooth Low Energy"), 2)
        XCTAssertEqual(LogitechButtonPolicy.nativeButton(cid: 0x53, transport: "Bluetooth"), 3)
        XCTAssertEqual(LogitechButtonPolicy.nativeButton(cid: 0x56, transport: "Bluetooth"), 4)
    }
    /// 插件开关不再跟「当前有没有设备」绑定：鼠标离线时开关保持开启，
    /// 只是不建立连接、不接管按键，重新连上会自动接管。
    @MainActor
    func testNoLogitechMouseKeepsSavedPreferenceEnabled() {
        let suite = "aurora.logitech.availability." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "logitech.enabled")
        let service = LogitechDeviceService(defaults: defaults, autoConnect: false, availabilityProvider: { false })
        XCTAssertFalse(service.isAvailable)
        XCTAssertTrue(service.isEnabled)
        // 离线时点开关仍然是「开」，但不会去连不存在的设备
        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.handleNativeButton(3))
        // 用户主动关掉才会真的关
        service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
    }

    /// 从没开过的机器上默认开启（模块开关才是总闸），但没有设备就不连接
    @MainActor
    func testNoLogitechMouseStaysIdleWhileEnabled() {
        let suite = "aurora.logitech.default." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LogitechDeviceService(defaults: defaults, autoConnect: false, availabilityProvider: { false })
        XCTAssertFalse(service.isAvailable)
        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(service.devices.isEmpty)
        XCTAssertFalse(service.handleNativeButton(3))
    }
    func testSpecialAndReceiverButtonsUseHIDPP() {
        for cid: UInt16 in [0x50, 0x51, 0xC4, 0xD7] {
            XCTAssertNil(LogitechButtonPolicy.nativeButton(cid: cid, transport: "Bluetooth Low Energy"))
        }
        XCTAssertNil(LogitechButtonPolicy.nativeButton(cid: 0x53, transport: "USB"))
    }
}
