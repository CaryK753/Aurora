import Foundation

// mihomo 外部控制器返回的数据结构。字段名按 API 文档，缺字段一律降级而不是抛错：
// 内核版本差异不该让整个仪表盘变空。

public struct ProxyTrafficSample: Equatable {
    public var up: Int
    public var down: Int
    public var upTotal: Int
    public var downTotal: Int
    public init(up: Int = 0, down: Int = 0, upTotal: Int = 0, downTotal: Int = 0) {
        self.up = up; self.down = down; self.upTotal = upTotal; self.downTotal = downTotal
    }
}

public struct ProxyDelayPoint: Decodable, Equatable {
    public var time: String?
    public var delay: Int
}

public struct ProxyEntry: Decodable, Equatable {
    public var name: String
    public var type: String
    public var now: String?
    public var all: [String]?
    public var alive: Bool?
    public var history: [ProxyDelayPoint]

    public var lastDelay: Int? { history.last?.delay }
    public var isGroup: Bool { all != nil }

    private enum CodingKeys: String, CodingKey { case name, type, now, all, alive, history }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        now = try c.decodeIfPresent(String.self, forKey: .now)
        all = try c.decodeIfPresent([String].self, forKey: .all)
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive)
        history = try c.decodeIfPresent([ProxyDelayPoint].self, forKey: .history) ?? []
    }
}

public struct ProxyConnectionSnapshot: Decodable, Equatable {
    public var downloadTotal: Int
    public var uploadTotal: Int
    public var memory: Int
    public var connections: [ProxyConnection]

    private enum CodingKeys: String, CodingKey { case downloadTotal, uploadTotal, memory, connections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try c.decodeIfPresent(Int.self, forKey: .downloadTotal) ?? 0
        uploadTotal = try c.decodeIfPresent(Int.self, forKey: .uploadTotal) ?? 0
        memory = try c.decodeIfPresent(Int.self, forKey: .memory) ?? 0
        connections = (try c.decodeIfPresent([ProxyConnection].self, forKey: .connections)) ?? []
    }
}

public struct ProxyConnection: Decodable, Identifiable, Equatable {
    public var id: String
    public var host: String
    public var destinationIP: String
    public var destinationPort: String
    public var sourceIP: String
    public var sourcePort: String
    public var network: String
    public var kind: String
    public var processPath: String
    public var upload: Int
    public var download: Int
    public var start: Date?
    public var chains: [String]
    public var rule: String
    public var rulePayload: String

    /// 域名优先，没有域名就显示目的 IP。
    public var target: String {
        if !host.isEmpty { return host }
        return destinationIP.isEmpty ? "—" : destinationIP
    }

    /// 连接实际的出站策略（chains 的第一个）。
    public var policy: String { chains.first ?? "" }

    public var ruleDescription: String {
        guard !rule.isEmpty else { return "" }
        return rulePayload.isEmpty ? rule : "\(rule)(\(rulePayload))"
    }

    public var processName: String {
        guard !processPath.isEmpty else { return "" }
        return (processPath as NSString).lastPathComponent
    }

    public func duration(now: Date = Date()) -> TimeInterval {
        guard let start else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    private enum MetadataKeys: String, CodingKey {
        case host, destinationIP, destinationPort, sourceIP, sourcePort, network, type, processPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        upload = try c.decodeIfPresent(Int.self, forKey: .upload) ?? 0
        download = try c.decodeIfPresent(Int.self, forKey: .download) ?? 0
        chains = (try c.decodeIfPresent([String].self, forKey: .chains)) ?? []
        rule = try c.decodeIfPresent(String.self, forKey: .rule) ?? ""
        rulePayload = try c.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
        let startText = try c.decodeIfPresent(String.self, forKey: .start)
        start = startText.flatMap(Self.date(from:))
        if let meta = try? c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata) {
            host = try meta.decodeIfPresent(String.self, forKey: .host) ?? ""
            destinationIP = try meta.decodeIfPresent(String.self, forKey: .destinationIP) ?? ""
            destinationPort = Self.text(meta, .destinationPort)
            sourceIP = try meta.decodeIfPresent(String.self, forKey: .sourceIP) ?? ""
            sourcePort = Self.text(meta, .sourcePort)
            network = try meta.decodeIfPresent(String.self, forKey: .network) ?? ""
            kind = try meta.decodeIfPresent(String.self, forKey: .type) ?? ""
            processPath = try meta.decodeIfPresent(String.self, forKey: .processPath) ?? ""
        } else {
            host = ""; destinationIP = ""; destinationPort = ""; sourceIP = ""; sourcePort = ""
            network = ""; kind = ""; processPath = ""
        }
    }

    private static func text<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return ""
    }

    /// mihomo 的 start 是 RFC3339Nano（`2026-01-02T03:04:05.123456789+08:00`）。
    /// ISO8601DateFormatter 只认毫秒，9 位小数会整条解析失败、时长永远显示 0，
    /// 所以先把小数部分截到 3 位再交给它。
    static func date(from text: String) -> Date? {
        let normalized = normalizeFraction(text)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    /// 只截时间部分的小数位，时区偏移里的数字不动。
    static func normalizeFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        let digits = text.distance(from: text.index(after: dot), to: end)
        guard digits > 3 else { return text }
        let keep = text.index(text.index(after: dot), offsetBy: 3)
        return String(text[text.startIndex..<keep]) + String(text[end...])
    }
}

public struct ProxyRuleInfo: Decodable, Identifiable, Equatable {
    public var index: Int
    public var type: String
    public var payload: String
    public var proxy: String
    public var hitCount: Int

    public var id: Int { index }

    private enum CodingKeys: String, CodingKey { case index, type, payload, proxy, extra }
    private enum ExtraKeys: String, CodingKey { case hitCount, disabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        payload = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
        proxy = try c.decodeIfPresent(String.self, forKey: .proxy) ?? ""
        if let extra = try? c.nestedContainer(keyedBy: ExtraKeys.self, forKey: .extra) {
            hitCount = try extra.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        } else {
            hitCount = 0
        }
    }
}

public struct ProxyLogLine: Decodable, Identifiable, Equatable {
    public var id = UUID()
    public var level: String
    public var message: String
    public var time = Date()

    private enum CodingKeys: String, CodingKey { case type, payload, level, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decodeIfPresent(String.self, forKey: .type)
            ?? c.decodeIfPresent(String.self, forKey: .level)
            ?? "info"
        message = try c.decodeIfPresent(String.self, forKey: .payload)
            ?? c.decodeIfPresent(String.self, forKey: .message)
            ?? ""
    }

    public static func local(_ text: String, level: String = "info") -> ProxyLogLine {
        ProxyLogLine(level: level, message: text)
    }

    private init(level: String, message: String) {
        self.level = level; self.message = message
    }
}

public enum ProxyControllerPayload {
    private static func decoder() -> JSONDecoder { JSONDecoder() }

    public static func traffic(_ data: Data) throws -> ProxyTrafficSample {
        struct Payload: Decodable { var up: Int?; var down: Int?; var upTotal: Int?; var downTotal: Int? }
        let value = try decoder().decode(Payload.self, from: data)
        return ProxyTrafficSample(up: value.up ?? 0, down: value.down ?? 0,
                                  upTotal: value.upTotal ?? 0, downTotal: value.downTotal ?? 0)
    }

    public static func connections(_ data: Data) throws -> ProxyConnectionSnapshot {
        try decoder().decode(ProxyConnectionSnapshot.self, from: data)
    }

    public static func proxies(_ data: Data) throws -> [String: ProxyEntry] {
        struct Payload: Decodable { var proxies: [String: ProxyEntry]? }
        return try decoder().decode(Payload.self, from: data).proxies ?? [:]
    }

    public static func rules(_ data: Data) throws -> [ProxyRuleInfo] {
        struct Payload: Decodable { var rules: [ProxyRuleInfo]? }
        return try decoder().decode(Payload.self, from: data).rules ?? []
    }

    public static func logLine(_ data: Data) throws -> ProxyLogLine? {
        guard !data.isEmpty else { return nil }
        return try decoder().decode(ProxyLogLine.self, from: data)
    }

    public static func delay(_ data: Data) throws -> Int {
        struct Payload: Decodable { var delay: Int?; var message: String? }
        let value = try decoder().decode(Payload.self, from: data)
        if let delay = value.delay { return delay }
        throw ProxyFailure(value.message ?? "测速失败")
    }
}

/// SSE / 长连接的行缓冲。按字节攒到换行再交给上层，避免半行 JSON 被解析。
public struct ProxyLineBuffer {
    private var buffer = Data()
    private let limit: Int

    public init(limit: Int = 1 << 20) { self.limit = limit }

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let slice = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            let line = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(line)
        }
        return lines
    }

    /// `data: {"up":1}` → `{"up":1}`；注释行、事件行、空行返回 nil。
    public static func payload(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
