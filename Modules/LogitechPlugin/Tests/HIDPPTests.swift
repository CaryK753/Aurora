import XCTest
@testable import LogitechPlugin

final class HIDPPTests: XCTestCase {
    func testPacketRoundTripAndReceiverIsolation() throws {
        let request = try HIDPPPacket.request(device: 3, feature: 7, function: 2, parameters: [1, 2])
        XCTAssertEqual(request.count, 20)
        XCTAssertEqual(Array(request.prefix(6)), [0x11, 3, 7, 0x2D, 1, 2])
        XCTAssertTrue(HIDPPPacket.matches(request, request: request))
        var unrelated = request
        unrelated[1] = 4
        XCTAssertFalse(HIDPPPacket.matches(unrelated, request: request))
        unrelated = request; unrelated[3] = 0x28
        XCTAssertFalse(HIDPPPacket.matches(unrelated, request: request))
        XCTAssertFalse(HIDPPPacket.matches([0x11, 3, 7], request: request))
    }

    func testDirectReplyAndErrors() throws {
        let request = try HIDPPPacket.request(device: 0xFF, feature: 9, function: 1, parameters: [])
        let direct: [UInt8] = [0x11, 0, 9, 0x1D, 1, 2, 3]
        XCTAssertTrue(HIDPPPacket.matches(direct, request: request))
        let error: [UInt8] = [0x11, 0, 0xFF, 9, 0x1D, 2, 0]
        XCTAssertTrue(HIDPPPacket.matches(error, request: request))
        XCTAssertThrowsError(try HIDPPPacket.payload(error))
        XCTAssertThrowsError(try HIDPPPacket.request(device: 0, feature: 1, function: 16, parameters: []))
        XCTAssertThrowsError(try HIDPPPacket.request(device: 0, feature: 1, function: 1, parameters: [1, 2, 3, 4], length: 7))
    }

    func testDPIListRangesAndInvalidData() throws {
        XCTAssertEqual(try LogitechDPI.decode([200, 0xE032, 400]), [200, 250, 300, 350, 400])
        XCTAssertEqual(try LogitechDPI.decode([800, 400, 800, 0]), [400, 800])
        XCTAssertThrowsError(try LogitechDPI.decode([0xE032, 400]))
        XCTAssertThrowsError(try LogitechDPI.decode([100, 0xE000, 8000]))
        XCTAssertThrowsError(try LogitechDPI.decode([100, 0xE001, 65535]))
    }

    func testProfilePersistenceAndWheelModes() throws {
        var device = LogitechDevice(id: "test", name: "Test Mouse", transport: "Bluetooth")
        device.dpi = 1000; device.wheelMode = 1; device.smartShiftThreshold = 255; device.torque = 50
        XCTAssertEqual(LogitechWheelChoice.current(device), .freeSpin)
        device.wheelMode = 2
        XCTAssertEqual(LogitechWheelChoice.current(device), .ratchet)
        device.smartShiftThreshold = 30
        XCTAssertEqual(LogitechWheelChoice.current(device), .automatic)
        let profile = LogitechProfile(name: "工作", device: device, bindings: ["196": "app:/Applications/Test.app"])
        let decoded = try JSONDecoder().decode(LogitechProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(profile, decoded)
    }

    func testEssentialButtonsCannotBeDiverted() {
        XCTAssertFalse(LogitechButton(id: 0x50, task: 0, flags: 0x20, diverted: false).canDivert)
        XCTAssertFalse(LogitechButton(id: 0x51, task: 0, flags: 0x20, diverted: false).canDivert)
        XCTAssertTrue(LogitechButton(id: 0xC4, task: 0, flags: 0x20, diverted: false).canDivert)
    }

    func testNotificationRouterIsolatesReceiverSlots() {
        let router = LogitechReportRouter()
        var slots: [Int] = []
        router.add(1) { _ in slots.append(1) }
        router.add(2) { _ in slots.append(2) }
        router.add(0xFF) { _ in slots.append(255) }
        router.receive([0x11, 2, 1, 0, 0, 0, 0])
        router.receive([0x11, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(slots, [2, 255])
    }
}
