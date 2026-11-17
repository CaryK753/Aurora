import NetworkProxyKit
import SwiftUI

struct NetworkRoutingOptionsView: View {
    @ObservedObject var service: SystemProxyService

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("规则与高级设置"), symbol: "arrow.triangle.branch")
                if service.profile.settings.mode == .rule {
                    Toggle(T("局域网和本机直连"), isOn: $service.profile.settings.bypassLAN)
                    Toggle(T("大陆 IP 智能直连（IPv4 / IPv6）"), isOn: $service.profile.settings.bypassMainland)
                    Toggle(T("使用订阅中的基础规则"), isOn: $service.profile.settings.useSubscriptionRules)
                    Toggle(T("未匹配的流量直连"), isOn: $service.profile.settings.fallbackDirect)
                    Toggle(T("启动时自动刷新过期地址库"), isOn: $service.profile.settings.refreshMainlandOnStart)
                    HStack {
                        Button(T("更新大陆 IP 地址库"), action: service.updateMainland)
                        Spacer()
                        if let date = service.mainlandUpdatedAt { Text(date, style: .date).font(.system(size: 10)) }
                    }
                    Text(T("使用 APNIC CN 分配数据，按域名解析后的目的 IP 判断；地址归属不等同于服务器物理位置。地址库缓存 7 天。"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    let skipped = ProxyRoutingRules.imported(service.profile.subscription.rules, mainland: service.profile.settings.bypassMainland).skipped
                    if service.profile.settings.useSubscriptionRules, skipped > 0 {
                        Text(TF("订阅中 %d 条外部规则或兜底规则不导入，以本页选项为准。", skipped))
                            .font(.system(size: 10.5)).foregroundStyle(.orange)
                    }
                    DisclosureGroup(T("自定义规则（优先匹配）")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(T("每行一条：DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、PROCESS-NAME、PROCESS-PATH、DST-PORT、SRC-PORT、NETWORK、MATCH；动作 DIRECT / PROXY / REJECT。"))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            TextEditor(text: $service.profile.settings.customRules)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 130)
                                .scrollContentBackground(.hidden)
                                .padding(5)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            Text("DOMAIN-SUFFIX,example.com,PROXY\nIP-CIDR,192.168.0.0/16,DIRECT,no-resolve")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup(T("连接选项")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(T("本地监听端口"))
                            TextField("17890", text: Binding(
                                get: { String(service.profile.settings.localPort) },
                                set: { service.profile.settings.localPort = Int($0.filter(\.isNumber).prefix(5)) ?? 0 }
                            ))
                            .textFieldStyle(.roundedBorder).frame(width: 75)
                        }
                        Toggle(T("启用 IPv6 解析"), isOn: $service.profile.settings.ipv6)
                        Text(T("DNS 服务器，每行一个 IP 或 DoH / DoT 地址"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        TextEditor(text: $service.profile.settings.dnsServers)
                            .font(.system(size: 11, design: .monospaced)).frame(height: 65)
                            .scrollContentBackground(.hidden)
                    }
                }
                Text(T("修改配置前请恢复原代理；再次应用后生效。本地内核只监听 127.0.0.1，不启用 TUN。"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(service.isBusy)
        }
    }
}
