import AppKit
import NetworkProxyKit
import SwiftUI

struct NetworkSubscriptionView: View {
    @ObservedObject var service: SystemProxyService
    @ObservedObject var tunnel: NetworkTunnelService
    @FocusState private var urlFocused: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: T("节点与订阅"), symbol: "server.rack")
                    Spacer()
                    if service.hasBackup {
                        Text(T("修改将在下次应用时生效"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                NetworkChoiceControl(selection: $service.profile.settings.source,
                    options: [("subscription", "订阅"), ("manual", "手动节点")])
                .disabled(service.isBusy)
                if service.profile.settings.source == "manual" {
                    manualFields
                } else {
                    subscriptionFields
                }
            }
        }
    }

    private var manualFields: some View {
        VStack(spacing: 8) {
            NetworkChoiceControl(selection: Binding(get: { tunnel.proxyKind }, set: { tunnel.updateKind($0) }),
                options: [(.http, "HTTP"), (.socks5, "SOCKS5")])
            HStack {
                TextField(T("主机，例如 127.0.0.1"), text: Binding(get: { tunnel.proxyHost }, set: { tunnel.updateHost($0) }))
                TextField("7890", text: Binding(get: { tunnel.proxyPort }, set: { tunnel.updatePort($0) }))
                    .frame(width: 65)
            }
            .textFieldStyle(.roundedBorder)
        }
        .disabled(service.isBusy)
    }

    private var subscriptionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("订阅地址")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("https://example.com/subscription", text: $service.profile.settings.subscriptionURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onSubmit(service.importSubscription)
                    .disabled(service.isBusy)
                Button(T("粘贴")) {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        service.profile.settings.subscriptionURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        urlFocused = true
                    }
                }
                .disabled(service.isBusy)
                if !service.profile.settings.subscriptionURL.isEmpty {
                    Button { service.profile.settings.subscriptionURL = ""; urlFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(T("清空订阅地址"))
                    .disabled(service.isBusy)
                }
            }
            HStack {
                Button(T("更新订阅"), action: service.importSubscription)
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isBusy || service.profile.settings.subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(T("导入配置文件"), action: service.importConfigurationFile)
                    .disabled(service.isBusy)
                Spacer()
                if let updated = service.profile.updatedAt {
                    Text(updated, style: .date).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !service.profile.subscription.nodes.isEmpty {
                Picker(T("当前节点"), selection: $service.profile.settings.selectedNode) {
                    ForEach(service.profile.subscription.nodes) { node in
                        Text(nodeTitle(node)).tag(node.name)
                    }
                }
                .disabled(service.isBusy)
                HStack {
                    Button(T(service.testingNodes ? "正在测试节点" : "测试全部节点"), action: service.testNodes)
                        .disabled(service.isBusy || service.testingNodes)
                    Spacer()
                    Picker(T("自动更新"), selection: Binding(
                        get: { service.profile.settings.subscriptionRefreshHours ?? 0 },
                        set: { service.updateRefreshInterval($0) }
                    )) {
                        Text(T("关闭")).tag(0)
                        Text(T("每 6 小时")).tag(6)
                        Text(T("每天")).tag(24)
                        Text(T("每 3 天")).tag(72)
                    }
                    .frame(width: 140)
                }
                Text(service.profile.subscription.format + " · \(service.profile.subscription.nodes.count) " + T("个节点"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Text(T("支持 Clash 内联节点、Shadowrocket 链接列表、Base64 订阅及本地配置文件。Surge 导入将在后续版本支持。"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !service.profile.subscription.warnings.isEmpty {
                DisclosureGroup(T("导入提示") + " (\(service.profile.subscription.warnings.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(service.profile.subscription.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(NetworkProxyLocalization.text(warning)).font(.system(size: 10.5)).foregroundStyle(.orange)
                            }
                        }
                    }.frame(maxHeight: 130)
                }
                .font(.system(size: 11))
            }
        }
    }

    private func nodeTitle(_ node: ProxyNode) -> String {
        let suffix: String
        if let latency = service.nodeLatencies[node.id] {
            suffix = " · \(latency) ms"
        } else if service.failedNodes.contains(node.id) {
            suffix = " · " + T("连接失败")
        } else {
            suffix = ""
        }
        return "\(node.name) · \(node.kind.uppercased())\(suffix)"
    }
}
