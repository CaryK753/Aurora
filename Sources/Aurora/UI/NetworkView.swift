//  NetworkView.swift
//  Aurora — 网络：规则 / 直连 / 全局，并写进系统设置的 VPN 列表

import SwiftUI

struct TunnelNetworkView: View {
    @ObservedObject var state: AppState
    @ObservedObject var service: NetworkTunnelService

    init(state: AppState) {
        self.state = state
        self.service = state.network
    }

    var body: some View {
        AdaptiveCardGrid(cards: {
            var cards = [AnyView(heroCard), AnyView(modeCard), AnyView(proxyCard)]
            if mode == .rule { cards.append(AnyView(rulesCard)) }
            cards.append(AnyView(infoCard))
            return cards
        }())
    }

    private var mode: NetworkTunnelService.Mode { service.mode }

    private var heroCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(service.isConnected ? AuroraTheme.accent.opacity(0.16) : Color.primary.opacity(0.06))
                            .frame(width: 54, height: 54)
                        Image(systemName: "network")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(service.isConnected ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(T("系统设置 › VPN"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(service.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: Binding(
                        get: { service.isConnected },
                        set: { on in
                            if on {
                                service.installAndApply(connect: true)
                            } else {
                                service.disconnect()
                            }
                        }
                    ))
                }

                HStack(spacing: 8) {
                    Button(action: service.openVPNSettings) {
                        Text(T("打开 VPN 列表"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AuroraTheme.accent)

                    if service.installState == .needsApproval {
                        Button(action: service.openExtensionSettings) {
                            Text(T("允许网络扩展"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AuroraTheme.accent)
                    }

                    Spacer()

                    Button {
                        service.installAndApply(connect: service.isConnected)
                        state.showToast(T("正在写入系统设置"), symbol: "network")
                    } label: {
                        Text(service.isBusy ? T("正在写入") : T("写入系统设置"))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(AuroraTheme.accentGradient))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isBusy)
                }

                if let lastError = service.lastError {
                    Text(lastError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("出站方式"), symbol: "arrow.triangle.branch")
                HStack(spacing: 5) {
                    ForEach(NetworkTunnelService.Mode.allCases) { item in
                        let active = service.mode == item
                        Button {
                            service.updateMode(item)
                        } label: {
                            Text(item.title)
                                .font(.system(size: 11, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background {
                                    Capsule().fill(
                                        active
                                            ? AnyShapeStyle(AuroraTheme.accentGradient)
                                            : AnyShapeStyle(Color.primary.opacity(0.05))
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(modeDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeDetail: String {
        switch service.mode {
        case .rule:
            return T("按下面的规则决定走代理还是直连。匹配不上的流量直连。")
        case .direct:
            return T("VPN 可以保持连接，但不接管流量。")
        case .global:
            return T("TCP 全部交给当前节点。")
        }
    }

    private var proxyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("代理节点"), symbol: "server.rack")
                HStack(spacing: 5) {
                    ForEach(NetworkTunnelService.ProxyKind.allCases) { item in
                        let active = service.proxyKind == item
                        Button {
                            service.updateKind(item)
                        } label: {
                            Text(item.title)
                                .font(.system(size: 11, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background {
                                    Capsule().fill(
                                        active
                                            ? AnyShapeStyle(AuroraTheme.accentGradient)
                                            : AnyShapeStyle(Color.primary.opacity(0.05))
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    TextField(T("主机，例如 127.0.0.1"), text: Binding(
                        get: { service.proxyHost },
                        set: { service.updateHost($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    TextField("7890", text: Binding(
                        get: { service.proxyPort },
                        set: { service.updatePort($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 64)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private var rulesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("规则"), symbol: "list.bullet")
                Text(T("DOMAIN-SUFFIX、DOMAIN、DOMAIN-KEYWORD、IP-CIDR、MATCH。动作是 DIRECT 或 PROXY。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { service.rulesText },
                    set: { service.updateRules($0) }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                if let issue = service.ruleIssues.first {
                    Text(TF("第 %d 行无法识别：%@", issue.line, issue.text))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var infoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("这一版接管什么"), symbol: "info.circle")
                Text(T("这一版接管 TCP。UDP 和 DNS 仍走系统原来的路径。名称在 VPN 列表里固定为 Aurora。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(T("加载扩展需要描述文件里有 Network Extension 授权。当前签名没有这项时，列表里还不会出现 Aurora。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
