import Foundation

public struct ProxyFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProxyMode: String, Codable, CaseIterable, Identifiable {
    case global, rule, direct
    public var id: String { rawValue }
}

public enum NetworkImplementation: String, CaseIterable {
    case system, tunnel, tailscale
    public static func preferred(saved: String?, extensionAvailable: Bool, hasBackup: Bool) -> Self {
        if hasBackup || !extensionAvailable { return .system }
        return saved.flatMap(Self.init(rawValue:)).flatMap { $0 == .tailscale ? nil : $0 } ?? .tunnel
    }
}

public struct ProxyNode: Codable, Identifiable, Equatable {
    public var name: String
    public var configuration: Data
    public var id: String { name }
    public var kind: String { (try? dictionary()["type"] as? String) ?? "" }
    public var endpoint: (host: String, port: Int)? {
        guard let value = try? dictionary(),
              let host = value["server"] as? String,
              let port = value["port"] as? Int else { return nil }
        return (host, port)
    }
    /// 订阅商常用伪节点展示流量、到期日或官网；保留供用户查看，但不自动选中。
    public var isLikelyStatusEntry: Bool {
        let value = name.lowercased()
        return ["剩余流量", "流量：", "流量:", "到期", "过期", "官网", "套餐",
                "traffic", "expire", "expiry", "subscription", "reset"].contains { value.contains($0) }
    }
    public init(_ dictionary: [String: Any]) throws {
        guard let name = dictionary["name"] as? String, !name.isEmpty,
              let host = dictionary["server"] as? String, !host.isEmpty, !host.contains(where: \.isWhitespace),
              let port = dictionary["port"] as? Int, (1...65535).contains(port),
              JSONSerialization.isValidJSONObject(dictionary) else { throw ProxyFailure("节点缺少有效名称、主机或端口") }
        self.name = name
        configuration = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }
    public func dictionary() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProxyFailure("节点配置无效")
        }
        return value
    }
}

public struct ProxySubscription: Codable {
    public var nodes: [ProxyNode]
    public var rules: [String]
    public var warnings: [String]
    public var format: String
    public init(nodes: [ProxyNode] = [], rules: [String] = [], warnings: [String] = [], format: String = "") {
        self.nodes = nodes; self.rules = rules; self.warnings = warnings; self.format = format
    }
}

public struct ProxySettings: Codable {
    public var source = "manual"
    public var subscriptionURL = ""
    public var selectedNode = ""
    public var mode: ProxyMode = .rule
    public var localPort = 17890
    public var bypassLAN = true
    public var bypassMainland = true
    public var fallbackDirect = false
    public var useSubscriptionRules = true
    public var customRules = ""
    public var dnsServers = "https://dns.alidns.com/dns-query\nhttps://doh.pub/dns-query"
    public var ipv6 = true
    public var refreshMainlandOnStart = true
    /// 0 表示关闭；其余值表示自动更新订阅的小时数。
    public var subscriptionRefreshHours: Int?
    public init() {}
}

public struct ProxyProfile: Codable {
    public var settings = ProxySettings()
    public var subscription = ProxySubscription()
    public var updatedAt: Date?
    public init() {}
}
