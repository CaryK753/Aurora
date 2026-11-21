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

/// 策略组类型：手动选点、自动测速、故障转移。对应 mihomo 的 Selector / URLTest / Fallback。
public enum ProxyGroupType: String, Codable, CaseIterable, Identifiable {
    case select, urlTest, fallback
    public var id: String { rawValue }

    public var engineType: String {
        switch self {
        case .select: return "select"
        case .urlTest: return "url-test"
        case .fallback: return "fallback"
        }
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
                "官网地址", "距离下次", "traffic", "expire", "expiry", "subscription", "reset"].contains {
            value.contains($0)
        }
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

public struct ProxySubscription: Codable, Equatable {
    public var nodes: [ProxyNode]
    public var rules: [String]
    public var warnings: [String]
    public var format: String
    public init(nodes: [ProxyNode] = [], rules: [String] = [], warnings: [String] = [], format: String = "") {
        self.nodes = nodes; self.rules = rules; self.warnings = warnings; self.format = format
    }
}

/// 一份订阅。多份可以并存，切换时只换当前使用的那份，不再互相覆盖。
public struct SubscriptionProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var url: String
    public var nodes: [ProxyNode]
    public var rules: [String]
    public var warnings: [String]
    public var format: String
    public var updatedAt: Date?
    /// 0 表示不自动更新，其余为小时数。
    public var refreshHours: Int

    public init(id: UUID = UUID(), name: String, url: String = "", nodes: [ProxyNode] = [], rules: [String] = [],
                warnings: [String] = [], format: String = "", updatedAt: Date? = nil, refreshHours: Int = 0) {
        self.id = id; self.name = name; self.url = url; self.nodes = nodes
        self.rules = rules; self.warnings = warnings; self.format = format
        self.updatedAt = updatedAt; self.refreshHours = refreshHours
    }

    public init(subscription: ProxySubscription, name: String, url: String = "", updatedAt: Date? = nil,
                refreshHours: Int = 0) {
        self.init(name: name, url: url, nodes: subscription.nodes, rules: subscription.rules,
                  warnings: subscription.warnings, format: subscription.format, updatedAt: updatedAt,
                  refreshHours: refreshHours)
    }

    public var payload: ProxySubscription {
        ProxySubscription(nodes: nodes, rules: rules, warnings: warnings, format: format)
    }

    /// 伪节点（流量、到期等）不进策略组。
    public var selectableNodes: [ProxyNode] { nodes.filter { !$0.isLikelyStatusEntry } }

    public static func suggestedName(for url: String, existing: [SubscriptionProfile]) -> String {
        let host = URL(string: url)?.host ?? ""
        let base = host.isEmpty ? "订阅" : host
        guard existing.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while existing.contains(where: { $0.name == "\(base) (\(index))" }) { index += 1 }
        return "\(base) (\(index))"
    }
}

/// 一条远程规则集。落到内核配置里是 rule-provider + RULE-SET。
public struct ProxyRuleSet: Codable, Identifiable, Equatable {
    public enum Behavior: String, Codable, CaseIterable, Identifiable {
        case domain, ipcidr, classical
        public var id: String { rawValue }
    }
    public var id: UUID
    public var name: String
    public var url: String
    public var behavior: Behavior
    public var intervalHours: Int
    public var enabled: Bool
    /// 命中的流量走代理还是直连。
    public var direct: Bool

    public init(id: UUID = UUID(), name: String, url: String, behavior: Behavior = .domain,
                intervalHours: Int = 24, enabled: Bool = true, direct: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.behavior = behavior
        self.intervalHours = intervalHours; self.enabled = enabled; self.direct = direct
    }

    /// provider 名要能直接当 mihomo 的标识用。
    public var providerName: String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let trimmed = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "aurora-" + (trimmed.isEmpty ? "rules" : trimmed)
    }

    public var isValid: Bool {
        let text = url.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), !name.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        return (1...720).contains(intervalHours)
    }
}

public struct ProxySettings: Codable {
    public var source = "manual"
    /// 旧字段：单订阅时代保存的地址。现在只在迁移时使用，新代码读 activeSubscription.url。
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
    /// 0 表示关闭；其余值表示自动更新订阅的小时数（旧字段，单订阅时代）。
    public var subscriptionRefreshHours: Int?

    /// 策略组类型与健康检查参数。
    public var groupType: ProxyGroupType = .select
    public var testURL = "https://www.gstatic.com/generate_204"
    public var healthCheckSeconds = 300
    public var tolerance = 50

    public var ruleSets: [ProxyRuleSet] = []
    /// 把 Tailscale 的组网出口并进规则：ts.net 与自选域名走 Tailscale。
    public var routeTailscale = true
    public var tailscaleDomains = ""

    /// 手动节点（不走订阅时直接用这些）。
    public var manualKind = "socks5"
    public var manualHost = "127.0.0.1"
    public var manualPort = 7890

    /// 下载测速用的地址。
    public var speedTestURL = "https://speed.cloudflare.com/__down?bytes=20000000"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case source, subscriptionURL, selectedNode, mode, localPort, bypassLAN, bypassMainland
        case fallbackDirect, useSubscriptionRules, customRules, dnsServers, ipv6, refreshMainlandOnStart
        case subscriptionRefreshHours, groupType, testURL, healthCheckSeconds, tolerance
        case ruleSets, routeTailscale, tailscaleDomains
        case manualKind, manualHost, manualPort, speedTestURL
    }

    /// 逐项 decodeIfPresent：合成解码器遇到缺字段会直接抛错，老配置就会整份失效。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProxySettings()
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? defaults.source
        subscriptionURL = try c.decodeIfPresent(String.self, forKey: .subscriptionURL) ?? defaults.subscriptionURL
        selectedNode = try c.decodeIfPresent(String.self, forKey: .selectedNode) ?? defaults.selectedNode
        mode = try c.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? defaults.mode
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? defaults.localPort
        bypassLAN = try c.decodeIfPresent(Bool.self, forKey: .bypassLAN) ?? defaults.bypassLAN
        bypassMainland = try c.decodeIfPresent(Bool.self, forKey: .bypassMainland) ?? defaults.bypassMainland
        fallbackDirect = try c.decodeIfPresent(Bool.self, forKey: .fallbackDirect) ?? defaults.fallbackDirect
        useSubscriptionRules = try c.decodeIfPresent(Bool.self, forKey: .useSubscriptionRules) ?? defaults.useSubscriptionRules
        customRules = try c.decodeIfPresent(String.self, forKey: .customRules) ?? defaults.customRules
        dnsServers = try c.decodeIfPresent(String.self, forKey: .dnsServers) ?? defaults.dnsServers
        ipv6 = try c.decodeIfPresent(Bool.self, forKey: .ipv6) ?? defaults.ipv6
        refreshMainlandOnStart = try c.decodeIfPresent(Bool.self, forKey: .refreshMainlandOnStart) ?? defaults.refreshMainlandOnStart
        subscriptionRefreshHours = try c.decodeIfPresent(Int.self, forKey: .subscriptionRefreshHours)
        groupType = try c.decodeIfPresent(ProxyGroupType.self, forKey: .groupType) ?? defaults.groupType
        testURL = try c.decodeIfPresent(String.self, forKey: .testURL) ?? defaults.testURL
        healthCheckSeconds = try c.decodeIfPresent(Int.self, forKey: .healthCheckSeconds) ?? defaults.healthCheckSeconds
        tolerance = try c.decodeIfPresent(Int.self, forKey: .tolerance) ?? defaults.tolerance
        ruleSets = try c.decodeIfPresent([ProxyRuleSet].self, forKey: .ruleSets) ?? defaults.ruleSets
        routeTailscale = try c.decodeIfPresent(Bool.self, forKey: .routeTailscale) ?? defaults.routeTailscale
        tailscaleDomains = try c.decodeIfPresent(String.self, forKey: .tailscaleDomains) ?? defaults.tailscaleDomains
        manualKind = try c.decodeIfPresent(String.self, forKey: .manualKind) ?? defaults.manualKind
        manualHost = try c.decodeIfPresent(String.self, forKey: .manualHost) ?? defaults.manualHost
        manualPort = try c.decodeIfPresent(Int.self, forKey: .manualPort) ?? defaults.manualPort
        speedTestURL = try c.decodeIfPresent(String.self, forKey: .speedTestURL) ?? defaults.speedTestURL
    }
}

public struct ProxyProfile: Codable {
    public var settings = ProxySettings()
    public var subscriptions: [SubscriptionProfile] = []
    public var activeSubscriptionID: UUID?
    public var updatedAt: Date?

    public init() {}

    public var activeSubscription: SubscriptionProfile? {
        if let id = activeSubscriptionID, let match = subscriptions.first(where: { $0.id == id }) { return match }
        return subscriptions.first
    }

    /// 旧接口：读写“当前订阅”。保留它，调用方不用到处改。
    public var subscription: ProxySubscription {
        get { activeSubscription?.payload ?? ProxySubscription() }
        set {
            if let id = activeSubscriptionID ?? activeSubscription?.id,
               let index = subscriptions.firstIndex(where: { $0.id == id }) {
                subscriptions[index].nodes = newValue.nodes
                subscriptions[index].rules = newValue.rules
                subscriptions[index].warnings = newValue.warnings
                subscriptions[index].format = newValue.format
            } else if !newValue.nodes.isEmpty || !newValue.rules.isEmpty {
                let profile = SubscriptionProfile(subscription: newValue, name: "默认")
                subscriptions.append(profile)
                activeSubscriptionID = profile.id
            }
        }
    }

    public var allNodes: [ProxyNode] {
        var seen = Set<String>()
        return subscriptions.flatMap(\.nodes).filter { seen.insert($0.name).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case settings, subscriptions, activeSubscriptionID, updatedAt, subscription
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(ProxySettings.self, forKey: .settings) ?? ProxySettings()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        if let list = try c.decodeIfPresent([SubscriptionProfile].self, forKey: .subscriptions) {
            subscriptions = list
            activeSubscriptionID = try c.decodeIfPresent(UUID.self, forKey: .activeSubscriptionID)
        } else if let legacy = try c.decodeIfPresent(ProxySubscription.self, forKey: .subscription),
                  !legacy.nodes.isEmpty || !legacy.rules.isEmpty {
            // 1.5.x 的 profile.json 只有一份订阅。
            let url = settings.subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = SubscriptionProfile(subscription: legacy,
                                              name: url.isEmpty ? "默认" : SubscriptionProfile.suggestedName(for: url, existing: []),
                                              url: url, updatedAt: updatedAt,
                                              refreshHours: settings.subscriptionRefreshHours ?? 0)
            subscriptions = [profile]
            activeSubscriptionID = profile.id
        }
        if activeSubscriptionID == nil { activeSubscriptionID = subscriptions.first?.id }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(settings, forKey: .settings)
        try c.encode(subscriptions, forKey: .subscriptions)
        try c.encodeIfPresent(activeSubscriptionID, forKey: .activeSubscriptionID)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
