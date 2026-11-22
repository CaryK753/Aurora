import Foundation

public enum ProxyConfiguration {
    /// 策略组与 "代理" 动作都指向这个名字。
    public static let groupName = "AURORA"
    /// Tailscale 出站（本机 userspace SOCKS5）在配置里的名字。
    public static let tailscaleName = "TAILSCALE"
    public static let mainlandProvider = "aurora-mainland"

    public static func generate(settings: ProxySettings,
                                subscription: ProxySubscription,
                                mainlandFile: String?,
                                controllerSocket: String? = nil,
                                tailscalePort: Int? = nil) throws -> Data {
        guard (1024...65535).contains(settings.localPort) else {
            throw ProxyFailure("本地监听端口必须在 1024–65535 之间")
        }
        let nodes = subscription.nodes.filter { !$0.isLikelyStatusEntry }
        let node = subscription.nodes.first { $0.name == settings.selectedNode }
        if settings.mode != .direct {
            guard !nodes.isEmpty else { throw ProxyFailure("订阅里没有可用节点") }
            guard let node, !node.isLikelyStatusEntry else { throw ProxyFailure("请先选择可用的代理节点") }
            let endpoint = try node.dictionary()
            let host = endpoint["server"] as? String ?? ""
            if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()),
               endpoint["port"] as? Int == settings.localPort {
                throw ProxyFailure("上游节点不能指向本地监听端口")
            }
        }
        guard (60...3600).contains(settings.healthCheckSeconds) else {
            throw ProxyFailure("健康检查间隔必须在 60–3600 秒之间")
        }
        guard (0...2000).contains(settings.tolerance) else { throw ProxyFailure("容差必须在 0–2000 毫秒之间") }
        let sets = settings.ruleSets.filter { $0.enabled }
        for set in sets where !set.isValid {
            throw ProxyFailure("规则集地址或更新周期无效")
        }
        let providerNames = sets.map(\.providerName)
        guard Set(providerNames).count == providerNames.count else {
            throw ProxyFailure("规则集名称重复，换一个名字再试")
        }

        let dns = settings.dnsServers.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !dns.isEmpty else { throw ProxyFailure("至少填写一个 DNS 服务器") }

        var config: [String: Any] = [
            "mixed-port": settings.localPort, "allow-lan": false, "bind-address": "127.0.0.1",
            "mode": "rule", "ipv6": settings.ipv6, "log-level": "info", "external-controller": "",
            "tun": ["enable": false], "profile": ["store-selected": false, "store-fake-ip": false],
            "dns": ["enable": true, "listen": "", "ipv6": settings.ipv6, "enhanced-mode": "redir-host",
                    "nameserver": dns, "default-nameserver": ["223.5.5.5", "119.29.29.29"]]
        ]
        if let controllerSocket, !controllerSocket.isEmpty {
            config["external-controller-unix"] = controllerSocket
        }

        var proxies: [[String: Any]] = []
        // 重名节点会让 mihomo 直接拒绝整份配置；订阅里重复命名很常见，这里按名字去重。
        var seen = Set<String>()
        for item in subscription.nodes where seen.insert(item.name).inserted {
            if let dictionary = try? item.dictionary() { proxies.append(dictionary) }
        }
        if let tailscalePort, seen.insert(tailscaleName).inserted {
            proxies.append(["name": tailscaleName, "type": "socks5", "server": "127.0.0.1",
                            "port": tailscalePort, "udp": false])
        }
        if !proxies.isEmpty { config["proxies"] = proxies }

        // 伪节点（流量、到期）留在 proxies 里给用户看，但不进策略组、也不参与选择。
        var nodeNames: [String] = []
        var nodeSeen = Set<String>()
        for item in nodes where nodeSeen.insert(item.name).inserted { nodeNames.append(item.name) }

        if settings.mode != .direct, !nodeNames.isEmpty {
            var group: [String: Any] = ["name": groupName, "type": settings.groupType.engineType,
                                        "proxies": nodeNames]
            if settings.groupType != .select {
                group["url"] = settings.testURL
                group["interval"] = settings.healthCheckSeconds
                group["lazy"] = false
                if settings.groupType == .urlTest { group["tolerance"] = settings.tolerance }
            }
            config["proxy-groups"] = [group]
        }

        var providers: [String: Any] = [:]
        if settings.mode == .rule {
            if settings.bypassMainland {
                guard let mainlandFile else { throw ProxyFailure("请先更新大陆 IP 地址库") }
                providers[mainlandProvider] = ["type": "file", "behavior": "ipcidr", "format": "yaml", "path": mainlandFile]
            }
            for set in sets {
                providers[set.providerName] = [
                    "type": "http", "url": set.url.trimmingCharacters(in: .whitespaces),
                    "behavior": set.behavior.rawValue, "format": "yaml",
                    "interval": set.intervalHours * 3600, "path": "rules/\(set.providerName).yaml",
                    "proxy": "DIRECT"
                ]
            }
            if !providers.isEmpty { config["rule-providers"] = providers }
        }

        switch settings.mode {
        case .direct:
            config["rules"] = ["MATCH,DIRECT"]
        case .global:
            config["rules"] = ["MATCH,\(groupName)"]
        case .rule:
            let plan = try ProxyRulePlanner.plan(settings: settings, subscription: subscription,
                                                 tailscaleAvailable: tailscalePort != nil)
            config["rules"] = plan.map(\.line)
        }
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
