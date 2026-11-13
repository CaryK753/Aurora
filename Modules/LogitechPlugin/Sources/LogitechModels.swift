import Foundation

public enum LogitechFailure: LocalizedError {
    case unavailable(String), timeout, rejected(UInt8), malformed, verification(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let text): return text
        case .timeout: return "鼠标未回复，请唤醒鼠标后重新连接；也请检查 Options+ 是否占用设备"
        case .rejected(let code): return "设备拒绝此操作（\(code)）"
        case .malformed: return "鼠标返回了不完整的数据"
        case .verification(let item): return "\(item)读回校验失败，界面已刷新为设备实际值"
        }
    }
}

public struct LogitechButton: Identifiable, Equatable, Sendable {
    public let id: UInt16
    public let task: UInt16
    public let flags: UInt16
    public var diverted: Bool
    public var canDivert: Bool { flags & 0x20 != 0 && id != 0x50 && id != 0x51 }
    public var name: String {
        switch id {
        case 0x50: return "左键"
        case 0x51: return "右键"
        case 0x52: return "中键／滚轮按下"
        case 0x53: return "后退侧键"
        case 0x56: return "前进侧键"
        case 0xC3: return "手势键"
        case 0xC4: return "滚轮模式切换键"
        default: return String(format: "特殊按键 0x%04X", id)
        }
    }
}

public struct LogitechDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let transport: String
    public var dpi: Int?
    public var supportedDPI: [Int] = []
    public var wheelMode: Int?
    public var smartShiftThreshold: Int?
    public var torque: Int?
    public var supportsTorque = false
    public var highResolution: Bool?
    public var buttons: [LogitechButton] = []
    public var features: [UInt16: UInt8] = [:]
    public var battery: Int?
    public init(id: String, name: String, transport: String) { self.id = id; self.name = name; self.transport = transport }
}

/// 曾经检测到过的罗技设备。鼠标离线后仍然保留，插件不会因为「暂时找不到设备」被关掉。
public struct LogitechKnownDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var transport: String
    /// 跨端口稳定的身份：优先用序列号，没有序列号时退回型号名
    public var identity: String
    public var firstSeen: Date
    public init(id: String, name: String, transport: String, identity: String, firstSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.transport = transport
        self.identity = identity
        self.firstSeen = firstSeen
    }
}

public struct LogitechProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let deviceID: String
    public var dpi: Int?
    public var wheelMode: Int?
    public var threshold: Int?
    public var torque: Int?
    public var highResolution: Bool?
    public var bindings: [String: String]
    public init(name: String, device: LogitechDevice, bindings: [String: String]) {
        id = UUID(); self.name = name; deviceID = device.id
        dpi = device.dpi; wheelMode = device.wheelMode; threshold = device.smartShiftThreshold
        torque = device.torque; highResolution = device.highResolution; self.bindings = bindings
    }
}

public enum HIDPPPacket {
    public static let softwareID: UInt8 = 0x0D
    public static func request(device: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8], length: Int = 20) throws -> [UInt8] {
        guard [7, 20].contains(length), function < 16, parameters.count <= length - 4 else { throw LogitechFailure.malformed }
        return [UInt8(length == 20 ? 0x11 : 0x10), device, feature, function << 4 | softwareID]
            + parameters + [UInt8](repeating: 0, count: length - 4 - parameters.count)
    }
    public static func matches(_ reply: [UInt8], request: [UInt8]) -> Bool {
        guard reply.count >= 7, request.count >= 4, [0x10, 0x11].contains(reply[0]),
              (request[1] == 0xFF ? [0, 0xFF].contains(reply[1]) : reply[1] == request[1]) else { return false }
        if reply[2] == 0xFF { return reply[3] == request[2] && reply[4] == request[3] }
        return reply[2] == request[2] && reply[3] == request[3]
    }
    public static func payload(_ reply: [UInt8]) throws -> [UInt8] {
        guard reply.count >= 7 else { throw LogitechFailure.malformed }
        if reply[2] == 0xFF { throw LogitechFailure.rejected(reply[5]) }
        return Array(reply.dropFirst(4))
    }
    public static func word(_ bytes: [UInt8], _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 1 < bytes.count else { throw LogitechFailure.malformed }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
    public static func bytes(_ word: Int) -> [UInt8] { [UInt8((word >> 8) & 255), UInt8(word & 255)] }
}
