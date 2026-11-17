//  TunnelProvider.swift
//  AuroraTunnel — 透明代理
//
//  NETransparentProxyManager 保存的配置会出现在「系统设置 › VPN」，名称用主 App 写入的 localizedDescription。
//  返回 false 的流由系统照原路直连。直连模式不声明任何 included 规则，列表里仍显示已连接，但不改流量。

import Foundation
import Network
import NetworkExtension
import os

@objc(AuroraTunnelProvider)
final class AuroraTunnelProvider: NETransparentProxyProvider {
    private let log = Logger(subsystem: "com.cary.aurora.tunnel", category: "proxy")
    private let queue = DispatchQueue(label: "com.cary.aurora.tunnel")
    private var relays: [UUID: TCPRelay] = [:]
    private var engine = ProxyRuleEngine(rules: [], issues: [])
    private var mode = "direct"
    private var proxyKind = "socks5"
    private var proxyHost = ""
    private var proxyPort = 0

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        loadConfig()
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if mode != "direct" {
            settings.includedNetworkRules = [
                NENetworkRule(
                    remoteNetworkEndpoint: nil,
                    remotePrefix: 0,
                    localNetworkEndpoint: nil,
                    localPrefix: 0,
                    protocol: .TCP,
                    direction: .outbound
                )
            ]
            if let excluded = excludedProxyRule() {
                settings.excludedNetworkRules = [excluded]
            }
        }
        log.info("start mode=\(self.mode, privacy: .public) proxy=\(self.proxyHost, privacy: .public):\(self.proxyPort)")
        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.sync {
            relays.values.forEach { $0.close() }
            relays.removeAll()
        }
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard mode != "direct", let tcp = flow as? NEAppProxyTCPFlow else { return false }
        guard let target = target(of: tcp) else { return false }
        if target.host.caseInsensitiveCompare(proxyHost) == .orderedSame, target.port == proxyPort {
            return false
        }
        let route: ProxyRoute = mode == "global" ? .proxy : engine.decide(host: target.host, port: target.port)
        guard route == .proxy, !proxyHost.isEmpty, (1...65535).contains(proxyPort) else { return false }
        guard let relay = TCPRelay(
            flow: tcp,
            host: target.host,
            port: target.port,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyKind: proxyKind
        ) else { return false }
        relay.onClose = { [weak self] id in
            self?.queue.async { self?.relays.removeValue(forKey: id) }
        }
        queue.sync { relays[relay.id] = relay }
        relay.start()
        return true
    }

    private func loadConfig() {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        mode = config[ProxyConfigKey.mode] as? String ?? "direct"
        proxyKind = config[ProxyConfigKey.proxyKind] as? String ?? "socks5"
        proxyHost = (config[ProxyConfigKey.proxyHost] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        proxyPort = config[ProxyConfigKey.proxyPort] as? Int ?? 0
        engine = ProxyRuleEngine.parse(config[ProxyConfigKey.rules] as? String ?? "")
    }

    private func target(of flow: NEAppProxyTCPFlow) -> (host: String, port: Int)? {
        guard case .hostPort(let host, let port) = flow.remoteFlowEndpoint else { return nil }
        let numeric: String
        switch host {
        case .name(let name, _):
            numeric = name
        case .ipv4(let address):
            numeric = "\(address)"
        case .ipv6(let address):
            numeric = "\(address)"
        @unknown default:
            return nil
        }
        let name = flow.remoteHostname.flatMap { $0.isEmpty ? nil : $0 } ?? numeric
        return (name, Int(port.rawValue))
    }

    /// 去代理节点的连接必须排除，否则扩展自己的出站会被自己再次接管。
    private func excludedProxyRule() -> NENetworkRule? {
        guard !proxyHost.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxyPort)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxyHost), port: port)
        if ProxyRuleEngine.ipv4(proxyHost) != nil {
            return NENetworkRule(destinationNetworkEndpoint: endpoint, prefix: 32, protocol: .TCP)
        }
        if proxyHost.contains(":") {
            return NENetworkRule(destinationNetworkEndpoint: endpoint, prefix: 128, protocol: .TCP)
        }
        return NENetworkRule(destinationHostEndpoint: endpoint, protocol: .TCP)
    }
}
