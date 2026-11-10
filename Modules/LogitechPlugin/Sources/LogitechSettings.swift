import Foundation

public enum LogitechDPI {
    public static func decode(_ words: [Int]) throws -> [Int] {
        var values: [Int] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == 0 { break }
            if word & 0xE000 == 0xE000 {
                let step = word & 0x1FFF
                guard step > 0, let start = values.last, index + 1 < words.count else { throw LogitechFailure.malformed }
                let end = words[index + 1]
                guard end >= start, end <= 65535, (end - start) / step < 4096 else { throw LogitechFailure.malformed }
                values += stride(from: start + step, through: end, by: step)
                index += 2
            } else {
                guard word > 0, word < 0xE000 else { throw LogitechFailure.malformed }
                values.append(word); index += 1
            }
        }
        return Array(Set(values)).sorted()
    }
}

public enum LogitechWheelChoice: Int, CaseIterable, Identifiable {
    case automatic, freeSpin, ratchet
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .automatic: return "SmartShift 自动"; case .freeSpin: return "自由滚动"; case .ratchet: return "分段滚动" }
    }
    public static func current(_ device: LogitechDevice) -> LogitechWheelChoice {
        device.wheelMode == 1 ? .freeSpin : (device.smartShiftThreshold == 255 ? .ratchet : .automatic)
    }
}

extension LogitechSession {
    func setDPI(_ dpi: Int) throws {
        guard let feature = state.features[0x2201], state.supportedDPI.contains(dpi) else {
            throw LogitechFailure.unavailable("此 DPI 不在设备报告的有效档位中")
        }
        _ = try request(feature: feature, function: 3, parameters: [0] + HIDPPPacket.bytes(dpi))
        let read = try request(feature: feature, function: 2, parameters: [0])
        state.dpi = try HIDPPPacket.word(read, 1)
        guard state.dpi == dpi else { throw LogitechFailure.verification("DPI") }
    }

    func setWheel(_ choice: LogitechWheelChoice, threshold: Int? = nil, torque: Int? = nil) throws {
        guard let feature = state.features[0x2111] ?? state.features[0x2110] else { throw LogitechFailure.unavailable("设备不支持 SmartShift") }
        let threshold = choice == .ratchet ? 255 : (threshold ?? (choice == .automatic && state.smartShiftThreshold == 255 ? 30 : state.smartShiftThreshold) ?? 30)
        guard (1...50).contains(threshold) || threshold == 255 else { throw LogitechFailure.unavailable("SmartShift 阈值超出范围") }
        if let torque { guard state.supportsTorque, (1...100).contains(torque) else { throw LogitechFailure.unavailable("设备不支持此滚轮阻尼") } }
        let mode = choice == .freeSpin ? 1 : 2
        let enhanced = state.features[0x2111] != nil
        var parameters = [UInt8(mode), UInt8(threshold)]
        if enhanced { parameters.append(UInt8(torque ?? state.torque ?? 0)) }
        _ = try request(feature: feature, function: enhanced ? 2 : 1, parameters: parameters)
        let read = try request(feature: feature, function: enhanced ? 1 : 0)
        guard read.count >= 2 else { throw LogitechFailure.malformed }
        state.wheelMode = Int(read[0]); state.smartShiftThreshold = Int(read[1])
        if state.supportsTorque && read.count > 2 { state.torque = Int(read[2]) }
        guard state.wheelMode == mode, state.smartShiftThreshold == threshold,
              torque == nil || state.torque == torque else { throw LogitechFailure.verification("滚轮设置") }
    }

    func setHighResolution(_ enabled: Bool) throws {
        guard let feature = state.features[0x2121] else { throw LogitechFailure.unavailable("设备没有高分辨率滚轮接口") }
        guard let mode = try request(feature: feature, function: 1).first else { throw LogitechFailure.malformed }
        let target = enabled ? mode | 2 : mode & ~2
        _ = try request(feature: feature, function: 2, parameters: [target])
        guard let actual = try request(feature: feature, function: 1).first else { throw LogitechFailure.malformed }
        state.highResolution = actual & 2 != 0
        guard state.highResolution == enabled else { throw LogitechFailure.verification("高分辨率滚轮") }
    }

    func setDiversion(_ cid: UInt16, enabled: Bool, restoring: Bool = false) throws {
        guard let feature = state.features[0x1B04], let button = state.buttons.first(where: { $0.id == cid }), button.canDivert else {
            throw LogitechFailure.unavailable("此按键不允许临时接管；左键和右键始终保留系统行为")
        }
        if !restoring && originalDiversion[cid] == nil {
            guard !button.diverted else { throw LogitechFailure.unavailable("此按键已被其他驱动接管，请先在 Options+ 中恢复默认") }
            originalDiversion[cid] = button.diverted
            onLeaseChanged?(originalDiversion)
        }
        _ = try request(feature: feature, function: 3,
                                  parameters: HIDPPPacket.bytes(Int(cid)) + [enabled ? 3 : 2, 0, 0])
        let read = try request(feature: feature, function: 2, parameters: HIDPPPacket.bytes(Int(cid)))
        guard read.count >= 3 else { throw LogitechFailure.malformed }
        let actual = read[2] & 1 != 0
        if let index = state.buttons.firstIndex(where: { $0.id == cid }) { state.buttons[index].diverted = actual }
        guard actual == enabled else { throw LogitechFailure.verification("特殊按键") }
        if !enabled { originalDiversion.removeValue(forKey: cid) }
        onLeaseChanged?(originalDiversion)
    }
}
