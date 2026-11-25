import SwiftUI

struct SettingsPermissionsView: View {
    @ObservedObject var service: PermissionService
    let openWelcome: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(T("系统权限")).font(.headline)
                    Spacer()
                    if service.isChecking { ProgressView().controlSize(.small) }
                    Button(T("重新检测"), systemImage: "arrow.clockwise", action: service.recheck)
                        .controlSize(.small).disabled(service.isChecking)
                }
                if let error = service.checkError {
                    Text(error).font(.caption).foregroundStyle(AuroraTheme.warn).textSelection(.enabled)
                }
                let items = service.items
                ForEach(items) { item in
                    Divider()
                    PermissionRow(item: item, service: service, compact: true)
                }
            }
        }
        Text(T("状态会自动复查；显示「重启生效」时，请重新启动 Aurora。无需重启 Mac。"))
            .font(.caption).foregroundStyle(.secondary)
        Button(T("欢迎与权限设置"), systemImage: "hand.raised", action: openWelcome)
    }
}
