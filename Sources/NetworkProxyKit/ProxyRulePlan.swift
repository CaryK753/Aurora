import Foundation

/// 规则来自哪里。用于界面上的来源标签与「规则测试」的解释。
public enum ProxyRuleOrigin: String, Codable, CaseIterable {
    case custom, tailscale, builtin, lan, mainland, ruleSet, subscription, fallback
}

public struct ProxyRuleEntry: Identifiable, Equatable {
    public var id: Int
    public var line: String
    public var origin: ProxyRuleOrigin
    /// 规则集名称、订阅名之类的补充说明。
    public var label: String?

    public init(id: Int, line: String, origin: ProxyRuleOrigin, label: String? = nil) {
        self.id = id; self.line = line; self.origin = origin; self.label = label
    }

    public var type: String {
        line.split(separator: ",", maxSplits: 1).first.map { $0.uppercased() } ?? ""
    }

    public var payload: String {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    public var policy: String {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        if type == "MATCH" { return parts.count > 1 ? String(parts[1]) : "" }
        return parts.count > 2 ? String(parts[2]) : ""
    }
}

/// 规则计划：生成内核配置和本地规则测试都用它，顺序只有一份定义。
public enum ProxyRulePlanner {
    public static func plan(settings: ProxySettings, subscription: ProxySubscription,
                            tailscaleAvailable: Bool = false,
                            groupName: String = ProxyConfiguration.groupName) throws -> [ProxyRuleEntry] {
        var lines: [(String, ProxyRuleOrigin, String?)] = []

        for (index, raw) in settings.customRules.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let normalized = ProxyRoutingRules.customLine(line, tailscaleAvailable: tailscaleAvailable) else {
                throw ProxyFailure("自定义规则第 \(index + 1) 行无效")
            }
            lines.append((normalized, .custom, nil))
        }

        if settings.routeTailscale, tailscaleAvailable {
            lines += ProxyRoutingRules.tailscaleLines(settings.tailscaleDomains)
        }

        for line in ProxyRoutingRules.builtInRules { lines.append((line, .builtin, nil)) }

        if settings.bypassLAN {
            for line in ProxyRoutingRules.lanRules { lines.append((line, .lan, nil)) }
        }

        if settings.bypassMainland {
            lines.append(("RULE-SET,aurora-mainland,DIRECT", .mainland, nil))
        }

        for set in settings.ruleSets where set.enabled && set.isValid {
            let action = set.direct ? "DIRECT" : groupName
            lines.append(("RULE-SET,\(set.providerName),\(action)", .ruleSet, set.name))
        }

        if settings.useSubscriptionRules {
            for line in ProxyRoutingRules.imported(subscription.rules, mainland: settings.bypassMainland).rules {
                lines.append((line, .subscription, nil))
            }
        }

        let fallback = settings.fallbackDirect ? "DIRECT" : groupName
        lines.append(("MATCH,\(fallback)", .fallback, nil))

        return lines.enumerated().map { index, item in
            ProxyRuleEntry(id: index, line: item.0, origin: item.1, label: item.2)
        }
    }
}

/// 本地规则测试：回答「这个域名会走哪条规则、哪个策略」。
/// 只做能确定的部分——IP 规则要看解析结果，规则集内容在文件里，进程规则要真实进程。
public enum ProxyRuleTester {
    public struct Skipped: Equatable {
        public var rule: ProxyRuleEntry
        public var reason: String
    }

    public struct Result: Equatable {
        public var host: String
        public var port: Int
        public var match: ProxyRuleEntry?
        public var policy: String
        public var skipped: [Skipped]
    }

    public static func test(host: String, port: Int = 443, plan: [ProxyRuleEntry]) -> Result {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = ipv4(name)
        var skipped: [Skipped] = []

        for entry in plan {
            let type = entry.type
            let payload = entry.payload.lowercased()
            switch type {
            case "DOMAIN":
                if address == nil, name == payload { return Result(host: name, port: port, match: entry, policy: entry.policy, skipped: skipped) }
            case "DOMAIN-SUFFIX":
                let suffix = payload.hasPrefix(".") ? String(payload.dropFirst()) : payload
                if address == nil, name == suffix || name.hasSuffix("." + suffix) {
                    return Result(host: name, port: port, match: entry, policy: entry.policy, skipped: skipped)
                }
            case "DOMAIN-KEYWORD":
                if address == nil, !payload.isEmpty, name.contains(payload) {
                    return Result(host: name, port: port, match: entry, policy: entry.policy, skipped: skipped)
                }
            case "IP-CIDR", "IP-CIDR6":
                guard let address, type == "IP-CIDR" else {
                    skipped.append(Skipped(rule: entry, reason: "需要解析目的地址"))
                    continue
                }
                let bits = payload.split(separator: "/", maxSplits: 1).map(String.init)
                if bits.count == 2, let network = ipv4(bits[0]), let prefix = Int(bits[1]),
                   cidr(address, network: network, prefix: prefix) {
                    return Result(host: name, port: port, match: entry, policy: entry.policy, skipped: skipped)
                }
            case "DST-PORT":
                if String(port) == payload { return Result(host: name, port: port, match: entry, policy: entry.policy, skipped: skipped) }
            case "RULE-SET":
                skipped.append(Skipped(rule: entry, reason: "规则集内容在本地文件里，运行时由内核判断"))
            case "PROCESS-NAME", "PROCESS-PATH":
                skipped.append(Skipped(rule: entry, reason: "需要真实进程上下文"))
            case "NETWORK":
                skipped.append(Skipped(rule: entry, reason: "需要连接上下文"))
            case "SRC-PORT":
                skipped.append(Skipped(rule: entry, reason: "需要源端口"))
            case "MATCH":
                return Result(host: name, port: port, match: entry, policy: entry.policy, skipped: skipped)
            default:
                skipped.append(Skipped(rule: entry, reason: "本地无法判断的规则类型"))
            }
        }
        return Result(host: name, port: port, match: nil, policy: "DIRECT", skipped: skipped)
    }

    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let number = UInt32(part), number < 256, !(part.count > 1 && part.hasPrefix("0")) else { return nil }
            value = (value << 8) | number
        }
        return value
    }

    static func cidr(_ address: UInt32, network: UInt32, prefix: Int) -> Bool {
        if prefix <= 0 { return true }
        if prefix >= 32 { return address == network }
        let mask = UInt32.max << (32 - prefix)
        return (address & mask) == (network & mask)
    }
}
