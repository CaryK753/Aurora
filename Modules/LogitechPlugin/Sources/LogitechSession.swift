import Foundation

/// 此对象仅从 service 的串行工作队列调用，接收通知另用锁保护。
final class LogitechSession: @unchecked Sendable {
    let transport: LogitechRequestTransport
    var state: LogitechDevice
    let deviceIndex: UInt8
    var onLeaseChanged: (([UInt16: Bool]) -> Void)?
    var originalDiversion: [UInt16: Bool] = [:]
    private let eventLock = NSLock()
    private var pressed = Set<UInt16>()
    var onButton: ((UInt16) -> Void)?

    init(transport: LogitechRequestTransport, state: LogitechDevice, deviceIndex: UInt8 = 0xFF) {
        self.transport = transport; self.state = state; self.deviceIndex = deviceIndex
    }

    func request(feature: UInt8, function: UInt8, parameters: [UInt8] = []) throws -> [UInt8] {
        try transport.transact(feature: feature, function: function, parameters: parameters, deviceIndex: deviceIndex)
    }

    func discover() throws {
        let ping = try request(feature: 0, function: 1, parameters: [0, 0, 0x6A])
        guard ping.count >= 3, ping[0] >= 2, ping[2] == 0x6A else { throw LogitechFailure.unavailable("此接口不是 HID++ 2.0 鼠标") }
        for feature: UInt16 in [0x2111, 0x2110, 0x2121, 0x2201, 0x1B04, 0x1004] {
            let data = try request(feature: 0, function: 0, parameters: HIDPPPacket.bytes(Int(feature)))
            if let index = data.first, index != 0 { state.features[feature] = index }
        }
        try refresh()
    }

    func refresh() throws {
        if let feature = state.features[0x2201] {
            let dpi = try request(feature: feature, function: 2, parameters: [0])
            state.dpi = try HIDPPPacket.word(dpi, 1)
            if state.dpi == 0 { state.dpi = try HIDPPPacket.word(dpi, 3) }
            if state.supportedDPI.isEmpty {
                var words: [Int] = []
                var complete = false
                for page: UInt8 in 0..<16 {
                    let data = try request(feature: feature, function: 1, parameters: [0, 0, page])
                    for offset in stride(from: 1, to: data.count - 1, by: 2) {
                        let word = try HIDPPPacket.word(data, offset)
                        if word == 0 { complete = true; break }
                        words.append(word)
                    }
                    if complete { break }
                }
                if complete { state.supportedDPI = try LogitechDPI.decode(words) }
            }
        }
        if let feature = state.features[0x2111] ?? state.features[0x2110] {
            let enhanced = state.features[0x2111] != nil
            let data = try request(feature: feature, function: enhanced ? 1 : 0)
            guard data.count >= 2 else { throw LogitechFailure.malformed }
            state.wheelMode = Int(data[0]); state.smartShiftThreshold = Int(data[1])
            if enhanced {
                let capabilities = try request(feature: feature, function: 0)
                state.supportsTorque = (capabilities.first ?? 0) & 1 != 0
                if state.supportsTorque, data.count > 2 { state.torque = Int(data[2]) }
            }
        }
        if let feature = state.features[0x2121] {
            let mode = try request(feature: feature, function: 1)
            state.highResolution = (mode.first ?? 0) & 2 != 0
        }
        if let feature = state.features[0x1B04] { try readButtons(feature) }
        if let feature = state.features[0x1004], let battery = try? request(feature: feature, function: 1), let level = battery.first, level <= 100 {
            state.battery = Int(level)
        }
    }

    private func readButtons(_ feature: UInt8) throws {
        let count = try request(feature: feature, function: 0).first ?? 0
        var buttons: [LogitechButton] = []
        for index in 0..<min(Int(count), 64) {
            let data = try request(feature: feature, function: 1, parameters: [UInt8(index)])
            guard data.count >= 5 else { throw LogitechFailure.malformed }
            let cid = UInt16(try HIDPPPacket.word(data, 0))
            let task = UInt16(try HIDPPPacket.word(data, 2))
            let flags = UInt16(data[4]) | (data.count > 8 ? UInt16(data[8]) << 8 : 0)
            let reporting = try request(feature: feature, function: 2, parameters: HIDPPPacket.bytes(Int(cid)))
            guard reporting.count >= 3 else { throw LogitechFailure.malformed }
            buttons.append(LogitechButton(id: cid, task: task, flags: flags, diverted: reporting[2] & 1 != 0))
        }
        state.buttons = buttons
    }

    func restoreButtons() {
        for (cid, diverted) in originalDiversion { try? setDiversion(cid, enabled: diverted, restoring: true) }
        onLeaseChanged?(originalDiversion)
    }

    func notification(_ report: [UInt8]) {
        guard report.count >= 7, report[2] == state.features[0x1B04], report[3] == 0 else { return }
        var now = Set<UInt16>()
        let data = Array(report.dropFirst(4))
        for offset in stride(from: 0, to: min(8, data.count - 1), by: 2) {
            if let cid = try? HIDPPPacket.word(data, offset), cid != 0 { now.insert(UInt16(cid)) }
        }
        eventLock.lock()
        let down = now.subtracting(pressed)
        pressed = now
        eventLock.unlock()
        for cid in down { onButton?(cid) }
    }
}
