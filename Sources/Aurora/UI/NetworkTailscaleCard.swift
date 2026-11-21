//  NetworkTailscaleCard.swift
//  Aurora — 网络 › Tailscale 组网

import AppKit
import NetworkProxyKit
import SwiftUI

struct NetworkTailscaleCard: View {
    @ObservedObject var service: TailscaleService
    @ObservedObject var system: SystemProxyService
    @State private var showPeers = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                if service.detecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(T("正在检测 Tailscale…")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                } else if service.isAvailable {
                    details
                } else {
                    guidance
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "point.3.filled.connected.trianglepath.dotted", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(T("Tailscale 组网")).font(.system(size: 12, weight: .semibold))
                    NetworkChip(text: T(stateTextKey), tint: stateTint, maxWidth: 150)
                }
                Text(subtitle)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if service.busy { ProgressView().controlSize(.small) }
            if service.isAvailable {
                AuroraToggle(isOn: Binding(
                    get: { service.snapshot.isRunning },
                    set: { on in
                        guard !service.busy else { return }
                        Task { if on { await service.connect() } else { await service.disconnect() } }
                    }
                ))
            }
        }
    }

    private var stateTextKey: String {
        if service.detecting { return T("检测中") }
        if case .unavailable = service.provider { return T("未安装") }
        return service.snapshot.stateText
    }

    private var stateTint: Color {
        if case .unavailable = service.provider { return .secondary }
        if service.snapshot.isRunning { return AuroraTheme.ok }
        if service.snapshot.needsLogin { return AuroraTheme.warn }
        return .secondary
    }

    private var subtitle: String {
        switch service.provider {
        case .unavailable:
            return T("没有检测到 Tailscale")
        case .officialApp:
            return service.snapshot.account.isEmpty ? T("使用已安装的官方 App") : service.snapshot.account
        case .userspace:
            return service.snapshot.account.isEmpty ? T("使用本机 tailscaled（userspace 模式）") : service.snapshot.account
        case .remoteCLI:
            return T("使用本机已在运行的 tailscaled")
        }
    }

    @ViewBuilder
    private var details: some View {
        if service.snapshot.isRunning {
            HStack(spacing: 8) {
                infoPill(symbol: "desktopcomputer", text: service.snapshot.hostName.isEmpty ? "—" : service.snapshot.hostName)
                infoPill(symbol: "network", text: service.snapshot.tailscaleIPs.first ?? "—")
                infoPill(symbol: "person.2", text: TF("%d / %d 在线", service.snapshot.onlinePeers, service.snapshot.peers.count))
                Spacer()
                if let exit = service.snapshot.exitNodeName, !exit.isEmpty {
                    NetworkChip(text: T("出口") + " " + exit, maxWidth: 140)
                }
            }
        }
        if let url = service.loginURL {
            HStack(spacing: 6) {
                Text(T("需要在浏览器里完成登录")).font(.system(size: 10.5)).foregroundStyle(AuroraTheme.warn)
                NetworkQuietButton(title: T("打开登录页"), tint: AuroraTheme.accent) {
                    if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                }
            }
        }
        if service.usesBundledDaemon {
            userspaceOutlet
        }
        if !service.snapshot.peers.isEmpty {
            DisclosureGroup(isExpanded: $showPeers) {
                peerList
            } label: {
                Text(T("节点") + " (\(service.snapshot.peers.count))").font(.system(size: 10.5))
            }
        }
        if let error = service.error {
            Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if !service.snapshot.health.isEmpty {
            Text(service.snapshot.health.joined(separator: " · "))
                .font(.system(size: 9.5)).foregroundStyle(AuroraTheme.warn).lineLimit(2)
        }
        Text(T("Tailscale 只用来组网：系统代理仍负责上网流量，规则里把 ts.net 与自选域名交给它。"))
            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var userspaceOutlet: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(T("组网出站"), isOn: $system.profile.settings.routeTailscale)
                    .toggleStyle(.switch).controlSize(.mini)
                if let port = service.outletPort {
                    Text("SOCKS5 127.0.0.1:\(port)")
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                } else {
                    Text(T("连接后才有出站端口")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if system.profile.settings.routeTailscale {
                TextField(T("额外走组网的域名，逗号分隔，例如 nas.example.com"), text: $system.profile.settings.tailscaleDomains)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5))
            }
        }
    }

    private var peerList: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(service.snapshot.peers) { peer in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(peer.online ? AuroraTheme.ok : Color.primary.opacity(0.2))
                            .frame(width: 5, height: 5)
                        Text(peer.displayName)
                            .font(.system(size: 11, weight: peer.active ? .semibold : .regular))
                            .lineLimit(1)
                        if !peer.os.isEmpty {
                            NetworkChip(text: peer.os, tint: .secondary, maxWidth: 90)
                        }
                        if peer.isExitNode {
                            NetworkChip(text: T("出口节点"), maxWidth: 80)
                        }
                        Spacer(minLength: 4)
                        Text(peer.ipv4 ?? "—")
                            .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                        if peer.canBeExitNode || peer.isExitNode {
                            Button(peer.isExitNode ? T("取消出口") : T("设为出口")) {
                                Task {
                                    await service.setExitNode(peer.isExitNode ? nil : peer)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5))
                            .foregroundStyle(AuroraTheme.accent)
                            .disabled(service.busy)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: 160)
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("装一个就能用：官方 App 用来开关与出口节点；装了 OSS 版 tailscaled（例如 brew install tailscale）时，Aurora 会自己拉起 userspace 实例，并给代理提供组网出站。"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NetworkQuietButton(title: T("下载 Tailscale"), tint: AuroraTheme.accent) {
                    service.openDownloadPage()
                }
                NetworkQuietButton(title: T("复制 brew 命令")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install tailscale", forType: .string)
                }
                Spacer()
            }
            Text(T("Aurora 不会把不存在的选项摆出来：没装就是没装。"))
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    private func infoPill(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 9.5, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
