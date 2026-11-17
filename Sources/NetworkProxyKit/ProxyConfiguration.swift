import Foundation

public enum ProxyConfiguration {
    public static func generate(settings: ProxySettings, subscription: ProxySubscription, mainlandFile: String?) throws -> Data {
        guard (1024...65535).contains(settings.localPort) else { throw ProxyFailure("本地监听端口必须在 1024–65535 之间") }
        let node = subscription.nodes.first { $0.name == settings.selectedNode }
        if settings.mode != .direct && node == nil { throw ProxyFailure("请先选择可用的代理节点") }
        if let node {
            let endpoint = try node.dictionary()
            let host = endpoint["server"] as? String ?? ""
            if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()), endpoint["port"] as? Int == settings.localPort {
                throw ProxyFailure("上游节点不能指向本地监听端口")
            }
        }
        let dns = settings.dnsServers.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !dns.isEmpty else { throw ProxyFailure("至少填写一个 DNS 服务器") }
        var config: [String: Any] = [
            "mixed-port": settings.localPort, "allow-lan": false, "bind-address": "127.0.0.1",
            "mode": "rule", "ipv6": settings.ipv6, "log-level": "warning", "external-controller": "",
            "tun": ["enable": false], "profile": ["store-selected": false],
            "dns": ["enable": true, "listen": "", "ipv6": settings.ipv6, "enhanced-mode": "redir-host", "nameserver": dns,
                    "default-nameserver": ["223.5.5.5", "119.29.29.29"]]
        ]
        if let node {
            config["proxies"] = [try node.dictionary()]
            config["proxy-groups"] = [["name": "AURORA", "type": "select", "proxies": [node.name]]]
        }
        var rules: [String]
        switch settings.mode {
        case .direct: rules = ["MATCH,DIRECT"]
        case .global: rules = ["MATCH,AURORA"]
        case .rule:
            rules = try ProxyRoutingRules.custom(settings.customRules)
            rules += ProxyRoutingRules.builtInRules
            if settings.bypassLAN {
                rules += ["DOMAIN,localhost,DIRECT", "DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-SUFFIX,lan,DIRECT"]
                rules += ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"].map { "IP-CIDR,\($0),DIRECT,no-resolve" }
                rules += ["::1/128", "fc00::/7", "fe80::/10"].map { "IP-CIDR6,\($0),DIRECT,no-resolve" }
            }
            if settings.bypassMainland {
                guard let mainlandFile else { throw ProxyFailure("请先更新大陆 IP 地址库") }
                config["rule-providers"] = ["aurora-mainland": ["type": "file", "behavior": "ipcidr", "format": "yaml", "path": mainlandFile]]
                // 允许解析域名，域名请求也按实际解析出的目的 IP 判断归属。
                rules.append("RULE-SET,aurora-mainland,DIRECT")
            }
            if settings.useSubscriptionRules {
                rules += ProxyRoutingRules.imported(subscription.rules, mainland: settings.bypassMainland).rules
            }
            rules.append("MATCH," + (settings.fallbackDirect ? "DIRECT" : "AURORA"))
        }
        config["rules"] = rules
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
