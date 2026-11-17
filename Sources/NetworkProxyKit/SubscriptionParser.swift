import Foundation
import Yams

public enum SubscriptionParser {
    public static let supportedTypes: Set<String> = ["ss", "ssr", "vmess", "vless", "trojan", "http", "socks5", "hysteria", "hysteria2", "tuic", "snell", "anytls"]

    public static func parse(_ data: Data) throws -> ProxySubscription {
        guard data.count <= 5 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ProxyFailure("订阅必须是小于 5 MB 的 UTF-8 配置")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var dictionaries: [[String: Any]] = []
        var result = ProxySubscription()
        if !trimmed.contains("://"), let decoded = decodeBase64(trimmed), decoded.contains("://") {
            return try parse(Data(decoded.utf8))
        }
        if trimmed.contains("[Proxy]") {
            dictionaries = ShadowrocketConfiguration.parse(trimmed, warnings: &result.warnings)
            result.format = "Shadowrocket"
        } else if trimmed.hasPrefix("proxies:") || trimmed.hasPrefix("{") || trimmed.contains("\nproxies:") {
            let yaml = try clashDictionary(trimmed)
            guard let nodes = yaml["proxies"] as? [[String: Any]] else {
                throw ProxyFailure("Clash 配置中没有内联 proxies 节点")
            }
            dictionaries = nodes
            result.format = "Clash"
            result.rules = yaml["rules"] as? [String] ?? []
            if yaml["proxy-providers"] != nil { result.warnings.append("外部节点 provider 未导入，请使用包含内联节点的订阅") }
            if yaml["proxy-groups"] != nil { result.warnings.append("订阅策略组已展开为节点选择；规则中的组策略统一使用所选节点") }
            if yaml["rule-providers"] != nil || yaml["script"] != nil {
                result.warnings.append("外部规则 provider 和脚本未导入")
            }
        } else {
            result.format = "Shadowrocket"
            for (index, line) in trimmed.components(separatedBy: .newlines).enumerated() {
                let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                do { dictionaries.append(try ProxyURIParser.parse(line)) }
                catch { result.warnings.append("第 \(index + 1) 行节点未导入：格式或协议不支持") }
            }
        }
        guard dictionaries.count <= 5000 else { throw ProxyFailure("订阅节点数量超过 5000") }
        var names = Set<String>()
        for (index, var node) in dictionaries.enumerated() {
            guard let type = node["type"] as? String, supportedTypes.contains(type.lowercased()) else {
                result.warnings.append("第 \(index + 1) 个节点协议不支持"); continue
            }
            node["type"] = type.lowercased()
            if let port = node["port"] as? String { node["port"] = Int(port) }
            if node["dialer-proxy"] != nil {
                result.warnings.append("第 \(index + 1) 个节点依赖代理链，未导入"); continue
            }
            let base = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Node \(index + 1)"
            var name = ["DIRECT", "REJECT", "AURORA", "GLOBAL"].contains(base) ? "\(base) (node)" : base
            var suffix = 2
            while names.contains(name) { name = "\(base) (\(suffix))"; suffix += 1 }
            node["name"] = name
            do {
                let proxy = try ProxyNode(node)
                result.nodes.append(proxy); names.insert(name)
            } catch { result.warnings.append("第 \(index + 1) 个节点配置无效，未导入") }
        }
        guard !result.nodes.isEmpty else { throw ProxyFailure("没有可用节点，请检查订阅格式或协议") }
        return result
    }

    private static func clashDictionary(_ text: String) throws -> [String: Any] {
        do {
            guard let root = try Yams.compose(yaml: text) else { throw ProxyFailure("Clash 配置无效") }
            var budget = 200_000
            try validate(root, depth: 0, budget: &budget)
            guard let value = root.any as? [String: Any] else { throw ProxyFailure("Clash 配置无效") }
            return value
        } catch { throw ProxyFailure("Clash 配置无效或嵌套过深") }
    }

    private static func validate(_ node: Yams.Node, depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth < 48, budget > 0 else { throw ProxyFailure("Clash 配置过于复杂") }
        switch node {
        case .scalar: break
        case .sequence(let sequence):
            for child in sequence { try validate(child, depth: depth + 1, budget: &budget) }
        case .mapping(let mapping):
            for (key, value) in mapping {
                try validate(key, depth: depth + 1, budget: &budget)
                try validate(value, depth: depth + 1, budget: &budget)
            }
        case .alias: throw ProxyFailure("Clash 配置别名无效")
        }
    }

    static func decodeBase64(_ value: String) -> String? {
        var text = value.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }
    }
}
