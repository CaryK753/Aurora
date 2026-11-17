import Foundation

public enum ProxyRoutingRules {
    private static let types: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "PROCESS-PATH", "DST-PORT", "SRC-PORT", "NETWORK", "MATCH"]

    /// 政务域名默认直连。DOMAIN-SUFFIX 同时覆盖 gov.cn 本身与任意层级子域名，
    /// 等价于用户常见的 `*.gov.cn` 写法。
    public static let builtInRules = ["DOMAIN-SUFFIX,gov.cn,DIRECT"]

    public static func custom(_ text: String) throws -> [String] {
        var rules: [String] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let normalized = normalize(line, subscription: false, mainland: false) else {
                throw ProxyFailure("自定义规则第 \(index + 1) 行无效")
            }
            rules.append(normalized)
        }
        return rules
    }

    public static func imported(_ lines: [String], mainland: Bool) -> (rules: [String], skipped: Int) {
        var result: [String] = []
        var skipped = 0
        for line in lines {
            // 兜底由用户的选项统一控制，不导入订阅的 MATCH。
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("MATCH,") { skipped += 1; continue }
            if let rule = normalize(line, subscription: true, mainland: mainland) { result.append(rule) }
            else { skipped += 1 }
        }
        return (result, skipped)
    }

    private static func normalize(_ line: String, subscription: Bool, mainland: Bool) -> String? {
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
        guard parts.count == actionIndex + 1 || (parts.count == actionIndex + 2 && parts.last == "no-resolve" && ["IP-CIDR", "IP-CIDR6", "GEOIP"].contains(type)),
              actionIndex == 1 || !parts[1].isEmpty else { return nil }
        let action = parts[actionIndex].uppercased()
        guard !action.isEmpty else { return nil }
        if ["DIRECT", "REJECT"].contains(action) { parts[actionIndex] = action }
        else if action == "PROXY" || subscription { parts[actionIndex] = "AURORA" }
        else { return nil }
        return parts.joined(separator: ",")
    }
}
