//  NetworkView.swift
//  Aurora — 网络：Surge 式一屏仪表盘
//
//  顶部常驻状态（模式 + 速率 + 累计），下面按「概览 / 连接 / 规则 / 日志」分页。
//  数据来自 ProxyMetricsService（mihomo 本机控制器），代理没跑时只有静态配置可看。

import NetworkProxyKit
import SwiftUI

struct NetworkView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview, connections, rules, logs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return T("概览")
            case .connections: return T("连接")
            case .rules: return T("规则")
            case .logs: return T("日志")
            }
        }
        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .connections: return "arrow.left.arrow.right"
            case .rules: return "list.bullet.rectangle"
            case .logs: return "text.alignleft"
            }
        }
    }

    @ObservedObject var state: AppState
    @ObservedObject private var system: SystemProxyService
    @ObservedObject private var metrics: ProxyMetricsService
    @ObservedObject private var tunnel: NetworkTunnelService
    @ObservedObject private var tailscale: TailscaleService
    @AppStorage("network.implementation") private var implementation = "system"
    /// 离屏预览用：AURORA_NETWORK_TAB=connections 时直接打开对应分页。
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["AURORA_NETWORK_TAB"] ?? "") ?? .overview

    init(state: AppState) {
        self.state = state
        self.system = state.systemProxy
        self.metrics = state.systemProxy.metrics
        self.tunnel = state.network
        self.tailscale = state.tailscale
    }

    var body: some View {
        VStack(spacing: 12) {
            NetworkImplementationCard(system: system, tunnel: tunnel)
            if implementation == "tunnel" {
                NetworkTunnelPage(state: state)
            } else {
                NetworkStatusCard(system: system, metrics: metrics)
                NetworkTabBar(selection: $tab, connections: metrics.connections.count, logs: metrics.logs.count)
                switch tab {
                case .overview:
                    NetworkOverviewTab(state: state, system: system, metrics: metrics, tunnel: tunnel, tailscale: tailscale)
                case .connections:
                    NetworkConnectionsTab(system: system, metrics: metrics)
                case .rules:
                    NetworkRulesTab(system: system, metrics: metrics)
                case .logs:
                    NetworkLogsTab(metrics: metrics)
                }
            }
        }
        .onAppear {
            implementation = NetworkImplementation.preferred(
                saved: UserDefaults.standard.string(forKey: "network.implementation"),
                extensionAvailable: NetworkSigningCapability.supportsExtension,
                hasBackup: system.hasBackup
            ).rawValue
            metrics.setVisible(true)
            tailscale.setVisible(true)
        }
        .onDisappear {
            metrics.setVisible(false)
            tailscale.setVisible(false)
        }
    }
}

// MARK: - 状态卡

private struct NetworkStatusCard: View {
    @ObservedObject var system: SystemProxyService
    @ObservedObject var metrics: ProxyMetricsService

    private var running: Bool { system.hasBackup }
    private var modeText: String {
        switch system.profile.settings.mode {
        case .global: return T("全局")
        case .rule: return T("规则")
        case .direct: return T("直连")
        }
    }

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                NetworkChoiceControl(selection: Binding(
                    get: { system.profile.settings.mode },
                    set: { system.profile.settings.mode = $0 }
                ), options: [(ProxyMode.global, "全局"), (ProxyMode.rule, "规则"), (ProxyMode.direct, "直连")])
                .disabled(running || system.isBusy)
                .opacity(running ? 0.55 : 1)
                if running {
                    Text(T("运行中改模式需先恢复原代理"))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }

                if running, metrics.live {
                    liveTraffic
                } else {
                    Text(running ? T("正在等待内核就绪…") : T("应用后这里会显示实时速率与本次会话流量。"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                if let error = system.error {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(T("打开网络设置"), action: system.openSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AuroraTheme.accent)
                    if running, let status = metrics.error, !status.isEmpty {
                        Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    NetworkPrimaryButton(title: running ? T("恢复原代理") : T("应用系统代理"),
                                         busy: system.isBusy,
                                         busyTitle: running ? T("正在恢复") : T("正在应用")) {
                        Task {
                            if running { system.restore() } else { await system.apply() }
                        }
                    }
                    .disabled(system.isBusy)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(running ? AuroraTheme.accent.opacity(0.16) : Color.primary.opacity(0.06))
                    .frame(width: 52, height: 52)
                Image(systemName: running ? "network.badge.shield.half.filled" : "network")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(running ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(running ? T("系统代理运行中") : T("系统代理未启用"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    NetworkChip(text: modeText, tint: running ? AuroraTheme.accent : Color.secondary, maxWidth: 56)
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if system.isBusy { ProgressView().controlSize(.small) }
            AuroraToggle(isOn: Binding(get: { running }, set: { on in
                guard !system.isBusy else { return }
                Task { if on { await system.apply() } else { system.restore() } }
            }))
        }
    }

    private var subtitle: String {
        if system.isBusy, !system.status.isEmpty { return system.status }
        if running {
            let port = system.profile.settings.localPort
            return T("正在把流量交给本机内核") + " · 127.0.0.1:\(port)"
        }
        if let node = system.activeSubscription?.name, !node.isEmpty {
            return node + " · " + T("选好模式后应用即可生效")
        }
        return T("选择模式并完成节点配置后应用")
    }

    private var liveTraffic: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    rateLine(symbol: "arrow.down", value: Double(metrics.downloadSpeed), color: AuroraTheme.accent)
                    rateLine(symbol: "arrow.up", value: Double(metrics.uploadSpeed), color: AuroraTheme.ok)
                }
                .frame(width: 118, alignment: .leading)

                Sparkline(values: metrics.history.map { Double($0.down) }, color: AuroraTheme.accent, filled: true)
                    .frame(height: 38)
                    .overlay(alignment: .topTrailing) {
                        Sparkline(values: metrics.history.map { Double($0.up) }, color: AuroraTheme.ok, filled: false)
                            .frame(height: 38)
                            .opacity(0.9)
                    }
            }
            HStack(spacing: 10) {
                Text(T("本次") + " ↓" + NetworkFormat.bytes(metrics.sample.downTotal) + "  ↑" + NetworkFormat.bytes(metrics.sample.upTotal))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if metrics.memory > 0 {
                    Text(T("内核") + " " + NetworkFormat.bytes(metrics.memory))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(NetworkFormat.duration(metrics.sessionDuration))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rateLine(symbol: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(Fmt.rate(value))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

// MARK: - 分页条

private struct NetworkTabBar: View {
    @Binding var selection: NetworkView.Tab
    var connections: Int
    var logs: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NetworkView.Tab.allCases) { tab in
                let active = selection == tab
                Button { withAnimation(.smooth(duration: 0.2)) { selection = tab } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 9.5, weight: .semibold))
                        Text(tab.title).font(.system(size: 11, weight: active ? .semibold : .regular))
                        if tab == .connections, connections > 0 {
                            Text("\(connections)")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(active ? Color.white.opacity(0.28) : Color.primary.opacity(0.08)))
                        }
                    }
                    .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.clear))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - 小部件

struct NetworkChip: View {
    var text: String
    var tint: Color = AuroraTheme.accent
    var maxWidth: CGFloat = 160

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

struct NetworkPrimaryButton: View {
    var title: String
    var busy: Bool = false
    var busyTitle: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(busy ? busyTitle : title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(AuroraTheme.accentGradient))
                .foregroundStyle(.white)
                .opacity(busy ? 0.65 : 1)
        }
        .buttonStyle(.plain)
    }
}

struct NetworkQuietButton: View {
    var title: String
    var tint: Color = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

enum NetworkFormat {
    static func rate(_ value: Int) -> String { Fmt.rate(Double(max(0, value))) }

    static func bytes(_ value: Int) -> String {
        guard value > 0 else { return "0 B" }
        return Fmt.bytes(Double(value))
    }

    static func duration(_ value: TimeInterval) -> String {
        guard value > 0 else { return "—" }
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func mbps(_ value: Double) -> String { String(format: "%.1f Mbit/s", value) }
}
