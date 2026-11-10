import XCTest
@testable import LogitechPlugin

private final class ScriptedTransport: LogitechRequestTransport {
    var handler: (UInt8, UInt8, [UInt8], UInt8) throws -> [UInt8] = { _, _, _, _ in [] }
    func transact(feature: UInt8, function: UInt8, parameters: [UInt8], deviceIndex: UInt8) throws -> [UInt8] {
        try handler(feature, function, parameters, deviceIndex)
    }
}

final class LogitechSettingsTests: XCTestCase {
    func testBluetoothStandardProfileDoesNotDivertNativeButton() throws {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "native", name: "Test", transport: "Bluetooth Low Energy")
        device.features[0x1B04] = 9
        device.buttons = [LogitechButton(id: 0x53, task: 0, flags: 0x20, diverted: false)]
        io.handler = { _, _, _, _ in XCTFail("Native side key must not be diverted"); return [] }
        let suite = "aurora.logitech.native." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = LogitechWorker(defaults: defaults)
        worker.sessions[device.id] = LogitechSession(transport: io, state: device)
        try worker.apply(LogitechProfile(name: "native", device: device, bindings: ["83": "back"]), previousBindings: [:])
        XCTAssertFalse(try worker.session(device.id).state.buttons[0].diverted)
    }

    func testDPIWriteMismatchKeepsActualReadback() throws {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "test", name: "Test", transport: "Bluetooth")
        device.features[0x2201] = 5; device.supportedDPI = [800, 1000]; device.dpi = 1000
        let session = LogitechSession(transport: io, state: device, deviceIndex: 3)
        io.handler = { feature, function, parameters, index in
            XCTAssertEqual(index, 3); XCTAssertEqual(feature, 5)
            if function == 3 { XCTAssertEqual(parameters, [0, 3, 32]); return [0, 0, 0] }
            return [0, 3, 232, 0, 0] // firmware kept 1000 instead of requested 800
        }
        XCTAssertThrowsError(try session.setDPI(800))
        XCTAssertEqual(session.state.dpi, 1000)
        XCTAssertThrowsError(try session.setDPI(900))
    }

    func testHighResolutionPreservesOtherModeBits() throws {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "test", name: "Test", transport: "Bluetooth")
        device.features[0x2121] = 8
        let session = LogitechSession(transport: io, state: device)
        var mode: UInt8 = 5
        io.handler = { _, function, parameters, _ in
            if function == 2 { mode = parameters[0]; return [mode, 0, 0] }
            return [mode, 0, 0]
        }
        try session.setHighResolution(true)
        XCTAssertEqual(mode, 7)
        try session.setHighResolution(false)
        XCTAssertEqual(mode, 5)
    }

    func testSmartShiftPreservesTorqueAndVerifiesThreshold() throws {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "test", name: "Test", transport: "Bluetooth")
        device.features[0x2111] = 7; device.wheelMode = 1; device.smartShiftThreshold = 255
        device.supportsTorque = true; device.torque = 50
        let session = LogitechSession(transport: io, state: device)
        var state: [UInt8] = [1, 255, 50]
        io.handler = { _, function, parameters, _ in
            if function == 2 { state = parameters; return state }
            return state
        }
        try session.setWheel(.automatic)
        XCTAssertEqual(state, [2, 30, 50])
        try session.setWheel(.ratchet)
        XCTAssertEqual(state, [2, 255, 50])
        XCTAssertThrowsError(try session.setWheel(.automatic, threshold: 90))
    }

    func testTemporaryDiversionLeaseAndRestore() throws {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "test", name: "Test", transport: "Bluetooth")
        device.features[0x1B04] = 9
        device.buttons = [LogitechButton(id: 0xC4, task: 0, flags: 0x20, diverted: false)]
        let session = LogitechSession(transport: io, state: device)
        var diverted = false
        var leaseSavedBeforeWrite = false
        session.onLeaseChanged = { values in if values[0xC4] == false { leaseSavedBeforeWrite = true } }
        io.handler = { _, function, parameters, _ in
            if function == 3 {
                XCTAssertTrue(leaseSavedBeforeWrite)
                XCTAssertEqual(Array(parameters.suffix(2)), [0, 0]) // keep remap unchanged
                diverted = parameters[2] & 1 != 0
            }
            return [0, 0xC4, diverted ? 1 : 0, 0, 0]
        }
        try session.setDiversion(0xC4, enabled: true)
        XCTAssertTrue(diverted)
        session.restoreButtons()
        XCTAssertFalse(diverted)
        XCTAssertTrue(session.originalDiversion.isEmpty)
    }

    func testHeldHardwareButtonOnlyFiresOnRisingEdge() {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "test", name: "Test", transport: "Bluetooth")
        device.features[0x1B04] = 9
        let session = LogitechSession(transport: io, state: device)
        var fired: [UInt16] = []
        session.onButton = { fired.append($0) }
        let down: [UInt8] = [0x11, 0xFF, 9, 0, 0, 0xC4, 0, 0]
        session.notification(down); session.notification(down)
        session.notification([0x11, 0xFF, 9, 0, 0, 0, 0, 0]); session.notification(down)
        session.notification([0x11])
        XCTAssertEqual(fired, [0xC4, 0xC4])
    }
    func testProfileFailureRollsBackHardwareDPI() throws {
        let io = ScriptedTransport()
        var device = LogitechDevice(id: "test", name: "Test", transport: "Bluetooth")
        device.features = [0x2201: 5, 0x2111: 7]
        device.dpi = 1000; device.supportedDPI = [800, 1000]
        device.wheelMode = 1; device.smartShiftThreshold = 255
        let session = LogitechSession(transport: io, state: device)
        let suite = "aurora.logitech.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = LogitechWorker(defaults: defaults)
        worker.sessions[device.id] = session
        var hardwareDPI = 1000
        var wheel: [UInt8] = [1, 255, 0]
        io.handler = { feature, function, parameters, _ in
            if feature == 5 {
                if function == 3 { hardwareDPI = try HIDPPPacket.word(parameters, 1) }
                return [0] + HIDPPPacket.bytes(hardwareDPI) + [0, 0]
            }
            if function == 2 {
                if parameters[1] == 30 { throw LogitechFailure.rejected(8) }
                wheel = parameters
            }
            return wheel
        }
        var target = LogitechProfile(name: "target", device: device, bindings: [:])
        target.dpi = 800; target.wheelMode = 2; target.threshold = 30
        XCTAssertThrowsError(try worker.apply(target, previousBindings: [:]))
        XCTAssertEqual(hardwareDPI, 1000)
        XCTAssertEqual(session.state.dpi, 1000)
        XCTAssertEqual(session.state.wheelMode, 1)
    }

}
