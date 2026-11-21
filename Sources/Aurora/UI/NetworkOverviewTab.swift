//  NetworkOverviewTab.swift
//  Aurora — 网络 › 概览：实现方案、策略组与节点、订阅、Tailscale、高级

import AppKit
import NetworkProxyKit
import SwiftUI

struct NetworkOverviewTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var system: SystemProxyService
    @ObservedObject var metrics: ProxyMetricsService
    @ObservedObject var tunnel: NetworkTunnelService
    @ObservedObject var tailscale: TailscaleService

    var body: some View {
        VStack(spacing: 12) {
            NetworkGroupCard(system: system, metrics: metrics)
            NetworkSubscriptionsCard(system: system)
            NetworkTailscaleCard(service: tailscale, system: system)
            NetworkAdvancedCard(system: system)
        }
    }
}

// MARK: - 实现方案

struct NetworkImplementationCard: View {
    @ObservedObject var system: SystemProxyService
    @ObservedObject var tunnel: NetworkTunnelService
    @AppStorage("network.implementation") private var implementation = "system"

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("实现方案"), symbol: "network")
                NetworkChoiceControl(selection: $implementation,
                                     options: [("system", "系统代理"), ("tunnel", "网络扩展")],
                                     unavailable: NetworkSigningCapability.supportsExtension ? [] : ["tunnel"])
                    .disabled(tunnel.isConnected || tunnel.isBusy || system.isLocked)
                Text(NetworkSigningCapability.supportsExtension
                     ? T("系统代理不要求开发者计划；网络扩展接管 TCP，需要带授权描述文件的签名。")
                     : T("当前签名没有可用的 Apple 网络扩展授权，默认使用系统代理。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 策略组与节点

private struct NetworkGroupCard: View {
    @ObservedObject var system: SystemProxyService
    @ObservedObject var metrics: ProxyMetricsService
    @State private var showAllNodes = false

    private var groupType: ProxyGroupType { system.profile.settings.groupType }
    private var nodes: [ProxyNode] { system.nodes }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: T("策略组"), symbol: "point.3.connected.trianglepath.dotted")
                    Spacer()
                    if let group = metrics.group, let now = group.now {
                        NetworkChip(text: now, maxWidth: 140)
                    }
                }
                NetworkChoiceControl(selection: Binding(
                    get: { groupType },
                    set: { system.rotateGroupType($0) }
                ), options: [(ProxyGroupType.select, "手动选择"),
                             (ProxyGroupType.urlTest, "自动测速"),
                             (ProxyGroupType.fallback, "故障转移")])
                Text(groupDetail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    NetworkQuietButton(title: system.testingNodes ? T("正在测速…") : T("测试全部节点"),
                                       tint: AuroraTheme.accent) {
                        Task { await system.testNodes() }
                    }
                    .disabled(system.testingNodes || nodes.isEmpty)
                    NetworkQuietButton(title: system.testingSpeed ? T("测速中…") : T("下载测速")) {
                        Task { await system.measureThroughput() }
                    }
                    .disabled(system.testingSpeed || !system.isRunning)
                    if let throughput = system.throughputMbps {
                        Text(NetworkFormat.mbps(throughput))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraTheme.accent)
                    }
                    Spacer()
                    Text(T("修改后下次应用生效"))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }

                if nodes.isEmpty {
                    Text(T("还没有可用节点，先添加订阅或填手动节点。"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    nodeList
                }

                DisclosureGroup(isExpanded: $showAllNodes) {
                    VStack(alignment: .leading, spacing: 6) {                        HStack {
                            Text(T("健康检查地址")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            TextField("https://www.gstatic.com/generate_204",
                                      text: $system.profile.settings.testURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                        }
                        HStack(spacing: 10) {
                            Text(T("间隔")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Stepper(value: $system.profile.settings.healthCheckSeconds, in: 60...3600, step: 60) {
                                Text("\(system.profile.settings.healthCheckSeconds) s")
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                            Spacer()
                            Text(T("容差")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Stepper(value: $system.profile.settings.tolerance, in: 0...1000, step: 10) {
                                Text("\(system.profile.settings.tolerance) ms")
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(T("健康检查"))
                        .font(.system(size: 10.5))
                }
            }
        }
    }

    private var groupDetail: String {
        switch groupType {
        case .select: return T("规则命中的流量都走你选中的那个节点。")
        case .urlTest: return T("内核按健康检查地址定期测速，自动用最快的节点。")
        case .fallback: return T("优先用列表里第一个可用节点，连不上才换下一个。")
        }
    }

    private var nodeList: some View {
        let visible = showLimit(nodes)
        return ScrollView {
            VStack(spacing: 3) {
                ForEach(visible) { node in
                    nodeRow(node)
                }
                if nodes.count > visible.count {
                    Button {
                        showAllNodes.toggle()
                    } label: {
                        Text(TF("还有 %d 个节点", nodes.count - visible.count))
                            .font(.system(size: 10)).foregroundStyle(AuroraTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 168)
    }

    private func showLimit(_ list: [ProxyNode]) -> [ProxyNode] {
        showAllNodes ? list : Array(list.prefix(6))
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let selected = system.selectedNode == node.name
        let delay = metrics.proxies[node.name]?.lastDelay ?? system.nodeLatencies[node.name]
        let failed = system.failedNodes.contains(node.name)
        return HStack(spacing: 8) {
            Circle()
                .fill(selected ? AuroraTheme.accent : Color.primary.opacity(0.18))
                .frame(width: 5, height: 5)
            Text(node.name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
            NetworkChip(text: node.kind.uppercased(), tint: .secondary)
            Spacer(minLength: 4)
            Text(delayText(delay, failed: failed))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(failed ? AuroraTheme.danger : (delay ?? 9999) < 300 ? AuroraTheme.ok : .secondary)
            if groupType == .select {
                Button(selected ? T("使用中") : T("使用")) {
                    system.selectNode(node.name)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.accent))
                .disabled(selected)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? AuroraTheme.accent.opacity(0.10) : Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture {
            guard groupType == .select, !selected else { return }
            system.selectNode(node.name)
        }
    }

    private func delayText(_ delay: Int?, failed: Bool) -> String {
        if failed { return T("超时") }
        guard let delay else { return "—" }
        return "\(delay) ms"
    }
}

// MARK: - 订阅

private struct NetworkSubscriptionsCard: View {
    @ObservedObject var system: SystemProxyService
    @State private var expandedWarnings = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: T("订阅"), symbol: "server.rack")
                    Spacer()
                    Text(TF("%d 份", system.subscriptions.count))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                NetworkChoiceControl(selection: $system.profile.settings.source,
                                     options: [("subscription", "订阅"), ("manual", "手动节点")])
                if system.profile.settings.source == "manual" {
                    manualFields
                } else {
                    subscriptionList
                }
                Text(T("订阅地址、密码与解析后的配置只存在本机，不上传第三方转换服务。"))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private var manualFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            NetworkChoiceControl(selection: Binding(
                get: { system.profile.settings.manualKind },
                set: { system.profile.settings.manualKind = $0 }
            ), options: [("socks5", "SOCKS5"), ("http", "HTTP")])
            HStack(spacing: 6) {
                TextField(T("主机，例如 127.0.0.1"), text: $system.profile.settings.manualHost)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10.5))
                TextField("7890", value: $system.profile.settings.manualPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 66)
            }
            Text(T("手动节点直接写进内核配置，不再经过订阅；应用后生效。"))
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var subscriptionList: some View {
        if system.subscriptions.isEmpty {
            Text(T("还没有订阅。粘一个地址，或者在下面导入本地配置文件。"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 3) {
                ForEach(system.subscriptions) { subscription in
                    row(subscription)
                }
            }
        }
        HStack(spacing: 6) {
            TextField("https://example.com/subscription", text: $system.draftSubscriptionURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5))
                .onSubmit { _ = system.addSubscription(urlString: system.draftSubscriptionURL) }
            Button {
                if let value = NSPasteboard.general.string(forType: .string) {
                    system.draftSubscriptionURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(T("粘贴订阅地址"))
            NetworkQuietButton(title: T("添加"), tint: AuroraTheme.accent) {
                _ = system.addSubscription(urlString: system.draftSubscriptionURL)
            }
            .disabled(system.draftSubscriptionURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack(spacing: 8) {
            NetworkQuietButton(title: system.isBusy ? T("处理中…") : T("更新当前订阅")) {
                Task { await system.updateActiveSubscription() }
            }
            .disabled(system.isBusy || system.activeSubscription == nil)
            NetworkQuietButton(title: T("导入配置文件")) { system.importConfigurationFile() }
                .disabled(system.isBusy)
            Spacer()
            if let updated = system.activeSubscription?.updatedAt {
                Text(Fmt.relative(updated)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
        if let subscription = system.activeSubscription {
            HStack(spacing: 8) {
                Text(T("自动更新")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { subscription.refreshHours },
                    set: { system.setRefresh(hours: $0, for: subscription.id) }
                )) {
                    Text(T("关闭")).tag(0)
                    Text(T("每 6 小时")).tag(6)
                    Text(T("每天")).tag(24)
                    Text(T("每 3 天")).tag(72)
                }
                .labelsHidden()
                .frame(width: 132)
                Spacer()
                if !subscription.format.isEmpty {
                    Text(subscription.format + " · " + TF("%d 个节点", subscription.nodes.count))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
        if let warnings = system.activeSubscription?.warnings, !warnings.isEmpty {
            DisclosureGroup(isExpanded: $expandedWarnings) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        Text(NetworkProxyLocalization.text(warning))
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 3)
            } label: {
                Text(T("导入提示") + " (\(warnings.count))").font(.system(size: 10.5))
            }
        }
    }

    private func row(_ subscription: SubscriptionProfile) -> some View {
        let active = system.activeSubscription?.id == subscription.id
        return HStack(spacing: 8) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(active ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(subscription.name)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle(subscription))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if system.isBusy, active { ProgressView().controlSize(.mini) }
            Button(T("更新")) {
                Task { await system.updateSubscription(subscription.id) }
            }
            .buttonStyle(.plain).font(.system(size: 9.5)).foregroundStyle(AuroraTheme.accent)
            .disabled(system.isBusy)
            Button {
                system.removeSubscription(subscription.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(T("删除这份订阅"))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(active ? AuroraTheme.accent.opacity(0.10) : Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { system.activate(subscription.id) }
    }

    private func subtitle(_ subscription: SubscriptionProfile) -> String {
        var parts: [String] = []
        if let host = URL(string: subscription.url)?.host { parts.append(host) }
        else if !subscription.url.isEmpty { parts.append(subscription.url) }
        if !subscription.format.isEmpty { parts.append(subscription.format) }
        parts.append(TF("%d 个节点", subscription.nodes.count))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 高级

private struct NetworkAdvancedCard: View {
    @ObservedObject var system: SystemProxyService

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("高级"), symbol: "slider.horizontal.3")
                HStack(spacing: 10) {
                    Text(T("本地端口")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    TextField("17890", value: $system.profile.settings.localPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .font(.system(size: 10.5, design: .monospaced))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        compactToggle("IPv6", $system.profile.settings.ipv6)
                        compactToggle("局域网直连", $system.profile.settings.bypassLAN)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        compactToggle("大陆 IP 直连", $system.profile.settings.bypassMainland)
                        compactToggle("订阅自带规则", $system.profile.settings.useSubscriptionRules)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        compactToggle("兜底直连", $system.profile.settings.fallbackDirect)
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 8) {
                    NetworkQuietButton(title: T("更新大陆地址库")) { system.updateMainland() }
                        .disabled(system.isLocked)
                    if let date = system.mainlandUpdatedAt {
                        Text(Fmt.relative(date)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    } else {
                        Text(T("还没有地址库")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    NetworkQuietButton(title: system.engineInstalled ? T("重装内核") : T("下载内核")) {
                        system.installEngine()
                    }
                    .disabled(system.isLocked)
                    if system.engineInstalled {
                        NetworkQuietButton(title: T("删除内核"), tint: AuroraTheme.danger) { system.removeEngine() }
                            .disabled(system.isLocked)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(T("DNS")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    TextEditor(text: $system.profile.settings.dnsServers)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(height: 52)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
                HStack(spacing: 8) {
                    Text(T("测速地址")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    TextField("https://speed.cloudflare.com/__down?bytes=20000000",
                              text: $system.profile.settings.speedTestURL)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                }
                Text(T("内核只监听 127.0.0.1，不接管 UDP 与系统 DNS；已有的系统绕过列表继续生效。"))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func compactToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(T(title)).font(.system(size: 10)).fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
