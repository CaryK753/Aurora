//  ProxyRuleEngine.swift
//  Aurora — 网络模块的规则子集
//
//  主 App 和网络扩展各编译一份。只认域名、网段和兜底，不解析 GEOIP / GEOSITE。

import Foundation

enum ProxyRoute: String, Equatable {
    case direct
    case proxy
}

enum ProxyConfigKey {
    static let mode = "mode"
    static let proxyKind = "proxyKind"
    static let proxyHost = "proxyHost"
    static let proxyPort = "proxyPort"
    static let rules = "rules"
}

struct ProxyRuleEngine {
    enum Kind: Equatable {
        case domainSuffix(String)
        case domain(String)
        case domainKeyword(String)
        case ipCIDR(UInt32, Int)
        case match
    }

    struct Rule: Equatable {
        var kind: Kind
        var route: ProxyRoute
    }

    struct Issue: Equatable {
        var line: Int
        var text: String
    }

    let rules: [Rule]
    let issues: [Issue]

    static let defaultText = """
    DOMAIN-SUFFIX,local,DIRECT
    IP-CIDR,10.0.0.0/8,DIRECT
    IP-CIDR,172.16.0.0/12,DIRECT
    IP-CIDR,192.168.0.0/16,DIRECT
    IP-CIDR,127.0.0.0/8,DIRECT
    MATCH,PROXY
    """

    static func parse(_ text: String) -> ProxyRuleEngine {
        var rules: [Rule] = []
        var issues: [Issue] = []
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            guard let rule = parseLine(line) else {
                issues.append(Issue(line: lineNumber, text: line))
                continue
            }
            rules.append(rule)
        }
        return ProxyRuleEngine(rules: rules, issues: issues)
    }

    func decide(host: String, port: Int) -> ProxyRoute {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = Self.ipv4(name)
        for rule in rules {
            switch rule.kind {
            case .domainSuffix(let suffix):
                guard address == nil else { continue }
                if name == suffix || name.hasSuffix("." + suffix) { return rule.route }
            case .domain(let domain):
                guard address == nil else { continue }
                if name == domain { return rule.route }
            case .domainKeyword(let keyword):
                guard address == nil else { continue }
                if name.contains(keyword) { return rule.route }
            case .ipCIDR(let network, let prefix):
                guard let address, Self.cidr(address, network: network, prefix: prefix) else { continue }
                return rule.route
            case .match:
                return rule.route
            }
        }
        _ = port
        return .direct
    }

    private static func parseLine(_ line: String) -> Rule? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 2 else { return nil }
        let head = parts[0].uppercased()
        if head == "MATCH" {
            guard parts.count == 2, let route = route(parts[1]) else { return nil }
            return Rule(kind: .match, route: route)
        }
        guard parts.count == 3, let route = route(parts[2]) else { return nil }
        let value = parts[1].lowercased()
        guard !value.isEmpty else { return nil }
        switch head {
        case "DOMAIN-SUFFIX":
            return Rule(kind: .domainSuffix(value.hasPrefix(".") ? String(value.dropFirst()) : value), route: route)
        case "DOMAIN":
            return Rule(kind: .domain(value), route: route)
        case "DOMAIN-KEYWORD":
            return Rule(kind: .domainKeyword(value), route: route)
        case "IP-CIDR":
            let bits = value.split(separator: "/", maxSplits: 1).map(String.init)
            guard bits.count == 2, let network = ipv4(bits[0]), let prefix = Int(bits[1]), (0...32).contains(prefix) else { return nil }
            return Rule(kind: .ipCIDR(network, prefix), route: route)
        default:
            return nil
        }
    }

    private static func route(_ text: String) -> ProxyRoute? {
        switch text.uppercased() {
        case "DIRECT": return .direct
        case "PROXY": return .proxy
        default: return nil
        }
    }

    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let number = UInt32(part), number < 256, part == Substring(String(number)) || part.count == 1 else { return nil }
            // "01" 这类前导零不当成地址，避免和域名规则搅在一起
            if part.count > 1, part.hasPrefix("0") { return nil }
            value = (value << 8) | number
        }
        return value
    }

    private static func cidr(_ address: UInt32, network: UInt32, prefix: Int) -> Bool {
        if prefix <= 0 { return true }
        if prefix >= 32 { return address == network }
        let mask = UInt32.max << (32 - prefix)
        return (address & mask) == (network & mask)
    }
}
