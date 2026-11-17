import NetworkProxyKit
import SwiftUI

struct NetworkView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var tunnel: NetworkTunnelService
    @ObservedObject private var system: SystemProxyService
    @AppStorage("network.implementation") private var implementation = "system"

    init(state: AppState) {
        self.state = state
        self.tunnel = state.network
        self.system = state.systemProxy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: T("实现方案"), symbol: "network")
                    NetworkChoiceControl(selection: $implementation,
                        options: [("system", "系统代理"), ("tunnel", "网络扩展")],
                        unavailable: NetworkSigningCapability.supportsExtension ? [] : ["tunnel"])
                    .disabled(tunnel.isConnected || tunnel.isBusy || system.isLocked)
                    if !NetworkSigningCapability.supportsExtension {
                        Text(T("当前签名没有可用的 Apple 网络扩展授权，默认使用系统代理。"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Text(T("Tailscale 组网将在后续版本接入。切换方案前请先关闭当前代理。"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if implementation == "system" {
                NetworkSystemProxyView(service: system, tunnel: tunnel)
            } else {
                TunnelNetworkView(state: state)
            }
        }
        .onAppear {
            implementation = NetworkImplementation.preferred(
                saved: UserDefaults.standard.string(forKey: "network.implementation"),
                extensionAvailable: NetworkSigningCapability.supportsExtension,
                hasBackup: system.hasBackup
            ).rawValue
        }
    }
}
