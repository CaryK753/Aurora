import Foundation

/// `tailscale status --json` 里我们真正用到的部分。
/// 官方 App 与自带的 tailscaled 输出同一份结构，所以两边共用一个模型。
public struct TailscalePeer: Identifiable, Equatable {
    public var id: String
    public var hostName: String
    public var dnsName: String
    public var os: String
    public var online: Bool
    public var active: Bool
    public var isExitNode: Bool
    public var canBeExitNode: Bool
    public var tailscaleIPs: [String]

    public var displayName: String {
        if !hostName.isEmpty { return hostName }
        return dnsName.split(separator: ".").first.map(String.init) ?? id
    }

    public var ipv4: String? { tailscaleIPs.first { $0.contains(".") } ?? tailscaleIPs.first }
}

public struct TailscaleSnapshot: Equatable {
    public var backendState: String
    public var version: String
    public var account: String
    public var hostName: String
    public var dnsName: String
    public var tailscaleIPs: [String]
    public var peers: [TailscalePeer]
    public var exitNodeName: String?
    public var magicDNSSuffix: String
    public var health: [String]

    public var isRunning: Bool { backendState == "Running" }
    public var needsLogin: Bool { backendState == "NeedsLogin" || backendState == "NeedsMachineAuth" }
    public var onlinePeers: Int { peers.filter(\.online).count }
    public var exitNodes: [TailscalePeer] { peers.filter { $0.canBeExitNode || $0.isExitNode } }

    public var stateText: String {
        switch backendState {
        case "Running": return "已连接"
        case "Stopped": return "未连接"
        case "Starting": return "正在连接"
        case "NeedsLogin": return "等待登录"
        case "NeedsMachineAuth": return "等待管理员批准"
        case "NoState", "": return "未初始化"
        default: return backendState
        }
    }

    public static let empty = TailscaleSnapshot(backendState: "NoState", version: "", account: "", hostName: "",
                                                dnsName: "", tailscaleIPs: [], peers: [], exitNodeName: nil,
                                                magicDNSSuffix: "", health: [])
}

public enum TailscaleStatusParser {
    public static func parse(_ data: Data) throws -> TailscaleSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProxyFailure("Tailscale 状态无法解析")
        }
        let selfInfo = root["Self"] as? [String: Any] ?? [:]
        let user = root["User"] as? [String: Any] ?? [:]
        let current = root["CurrentTailnet"] as? [String: Any] ?? [:]
        let exitStatus = root["ExitNodeStatus"] as? [String: Any]

        var peers: [TailscalePeer] = []
        for (key, value) in (root["Peer"] as? [String: Any] ?? [:]) {
            guard let peer = value as? [String: Any] else { continue }
            peers.append(TailscalePeer(
                id: peer["ID"] as? String ?? key,
                hostName: peer["HostName"] as? String ?? "",
                dnsName: peer["DNSName"] as? String ?? "",
                os: peer["OS"] as? String ?? "",
                online: peer["Online"] as? Bool ?? false,
                active: peer["Active"] as? Bool ?? false,
                isExitNode: peer["ExitNode"] as? Bool ?? false,
                canBeExitNode: peer["ExitNodeOption"] as? Bool ?? false,
                tailscaleIPs: peer["TailscaleIPs"] as? [String] ?? []
            ))
        }
        peers.sort { ($0.online ? 0 : 1, $0.displayName.lowercased()) < ($1.online ? 0 : 1, $1.displayName.lowercased()) }

        var exitNodeName: String?
        if let id = exitStatus?["ID"] as? String {
            exitNodeName = peers.first { $0.id == id }?.displayName ?? id
        }

        return TailscaleSnapshot(
            backendState: root["BackendState"] as? String ?? "NoState",
            version: root["Version"] as? String ?? "",
            account: user["LoginName"] as? String ?? user["DisplayName"] as? String ?? "",
            hostName: selfInfo["HostName"] as? String ?? "",
            dnsName: selfInfo["DNSName"] as? String ?? "",
            tailscaleIPs: selfInfo["TailscaleIPs"] as? [String] ?? [],
            peers: peers,
            exitNodeName: exitNodeName,
            magicDNSSuffix: current["MagicDNSSuffix"] as? String ?? "",
            health: root["Health"] as? [String] ?? []
        )
    }
}
