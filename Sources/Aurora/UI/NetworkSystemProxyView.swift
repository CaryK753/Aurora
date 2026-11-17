import NetworkProxyKit
import SwiftUI

struct NetworkSystemProxyView: View {
    @ObservedObject var service: SystemProxyService
    @ObservedObject var tunnel: NetworkTunnelService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlCard
            NetworkSubscriptionView(service: service, tunnel: tunnel)
            NetworkRoutingOptionsView(service: service)
        }
    }

    private var controlCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: service.hasBackup ? "checkmark.circle.fill" : "globe")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(service.hasBackup ? AnyShapeStyle(.green) : AnyShapeStyle(AuroraTheme.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T(service.hasBackup ? "系统代理运行中" : "系统代理未启用"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(T(service.hasBackup ? "可以继续编辑，恢复后重新应用生效" : "选择模式并完成节点配置后应用"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if service.isBusy { ProgressView().controlSize(.small) }
                }
                Divider()
                Text(T("流量模式")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                NetworkChoiceControl(selection: $service.profile.settings.mode,
                    options: [(.global, "全局"), (.rule, "规则"), (.direct, "直连")])
                .disabled(service.isBusy)
                Text(T(detail))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(T("打开网络设置"), action: service.openSettings)
                    Spacer()
                    Button(T(service.hasBackup ? "恢复原代理配置" : "应用系统代理")) {
                        if service.hasBackup { service.restore() }
                        else { service.apply(manual: tunnel) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(service.isBusy || tunnel.isConnected || tunnel.isBusy)
                }
                if !service.status.isEmpty { Text(service.status).font(.system(size: 11)) }
                if let error = service.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text(T("仅遵循系统代理的应用生效。写入可能需要管理员授权；正常退出时自动恢复。原有系统绕过列表仍生效。"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(T("代理内核与系统说明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(T(service.engineInstalled ? "代理内核已就绪" : "首次使用需下载代理内核"),
                                  systemImage: service.engineInstalled ? "checkmark.seal.fill" : "arrow.down.circle")
                            Spacer()
                            Button(T(service.engineInstalled ? "重新安装内核" : "下载内核"), action: service.installEngine)
                                .disabled(service.isLocked)
                            if service.engineInstalled {
                                Button(T("删除内核"), action: service.removeEngine).disabled(service.isLocked)
                            }
                        }
                        Text(T("mihomo 不包含在 Aurora 安装包内，仅首次使用时单独下载；删除后直连模式仍可使用。"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Link(T("mihomo 开源项目与许可"), destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
                            .font(.system(size: 10.5))
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private var detail: String {
        switch service.profile.settings.mode {
        case .global: return "所有进入系统代理的连接使用所选节点。"
        case .rule: return "按自定义规则、局域网、大陆 IP、订阅规则、兜底策略依次匹配。"
        case .direct: return "关闭当前网络服务的代理设置，连接直接出站；无需代理内核。"
        }
    }
}
