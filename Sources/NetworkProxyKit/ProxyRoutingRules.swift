import Foundation

public enum ProxyRoutingRules {
    /// 自定义规则能写的类型。判定顺序与内核一致，别在这个列表里加内核不认的类型。
    private static let types: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6",
                                             "PROCESS-NAME", "PROCESS-PATH", "DST-PORT", "SRC-PORT", "NETWORK", "MATCH"]

    /// 政务域名默认直连。DOMAIN-SUFFIX 同时覆盖 gov.cn 本身与任意层级子域名，
    /// 等价于用户常见的 `*.gov.cn` 写法。
    public static let builtInRules = ["DOMAIN-SUFFIX,gov.cn,DIRECT"]

    /// 局域网与本机直连。被系统代理的流量里仍会出现这些地址，不绕开就会全塞进代理。
    public static let lanRules: [String] = {
        var rules = ["DOMAIN,localhost,DIRECT", "DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-SUFFIX,lan,DIRECT"]
        rules += ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
            .map { "IP-CIDR,\($0),DIRECT,no-resolve" }
        rules += ["::1/128", "fc00::/7", "fe80::/10"].map { "IP-CIDR6,\($0),DIRECT,no-resolve" }
        return rules
    }()

    public static func custom(_ text: String) throws -> [String] {
        var rules: [String] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let normalized = customLine(line) else {
                throw ProxyFailure("自定义规则第 \(index + 1) 行无效")
            }
            rules.append(normalized)
        }
        return rules
    }

    /// 单行自定义规则：允许 DIRECT / REJECT / AURORA / TAILSCALE 四种动作。
    /// 没有可用的 Tailscale 出口时不接受 TAILSCALE，免得写进内核配置直接校验失败。
    public static func customLine(_ line: String, tailscaleAvailable: Bool = false) -> String? {
        normalize(line, subscription: false, mainland: false, tailscaleAvailable: tailscaleAvailable)
    }

    /// Tailscale 组网出站：`.ts.net`（MagicDNS）在内，外加用户自己列的后缀。
    public static func tailscaleLines(_ domains: String) -> [(String, ProxyRuleOrigin, String?)] {
        var lines: [(String, ProxyRuleOrigin, String?)] = [("DOMAIN-SUFFIX,ts.net,TAILSCALE", .tailscale, "MagicDNS")]
        for raw in domains.components(separatedBy: CharacterSet(charactersIn: ",，\n")) {
            var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasPrefix("*.") { domain = String(domain.dropFirst(2)) }
            if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
            guard !domain.isEmpty, domain.count <= 253, !domain.contains(where: \.isWhitespace),
                  domain.contains("."), domain.split(separator: ".").allSatisfy({ !$0.isEmpty }) else { continue }
            lines.append(("DOMAIN-SUFFIX,\(domain),TAILSCALE", .tailscale, domain))
        }
        return lines
    }

    public static func imported(_ lines: [String], mainland: Bool) -> (rules: [String], skipped: Int) {
        var result: [String] = []
        var skipped = 0
        for line in lines {
            // 兜底由用户的选项统一控制，不导入订阅的 MATCH。
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("MATCH,") { skipped += 1; continue }
            if let rule = normalize(line, subscription: true, mainland: mainland, tailscaleAvailable: false) { result.append(rule) }
            else { skipped += 1 }
        }
        return (result, skipped)
    }

    private static func normalize(_ line: String, subscription: Bool, mainland: Bool,
                                  tailscaleAvailable: Bool = false) -> String? {
        var parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let rawType = parts.first else { return nil }
        let type = rawType.uppercased()
        if subscription, type == "GEOIP", parts.count >= 3, parts[1].uppercased() == "CN", mainland {
            parts[0] = "RULE-SET"; parts[1] = "aurora-mainland"
        } else {
            guard types.contains(type) else { return nil }
            parts[0] = type
        }
        let actionIndex = type == "MATCH" ? 1 : 2
        guard parts.count == actionIndex + 1
                || (parts.count == actionIndex + 2 && parts.last == "no-resolve"
                    && ["IP-CIDR", "IP-CIDR6", "GEOIP"].contains(type)),
              actionIndex == 1 || !parts[1].isEmpty else { return nil }
        let action = parts[actionIndex].uppercased()
        guard !action.isEmpty else { return nil }
        if subscription {
            // 订阅里的策略名一律改成我们自己的组，避免指向不存在的节点。
            parts[actionIndex] = ["DIRECT", "REJECT"].contains(action) ? action : "AURORA"
        } else {
            var allowed = ["DIRECT", "REJECT", "AURORA", "PROXY"]
            if tailscaleAvailable { allowed.append("TAILSCALE") }
            guard allowed.contains(action) else { return nil }
            // PROXY 是旧文档里的写法，继续接受，落到自己的策略组。
            parts[actionIndex] = action == "PROXY" ? "AURORA" : action
        }
        return parts.joined(separator: ",")
    }
}
