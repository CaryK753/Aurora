import SwiftUI

struct PermissionRow: View {
    let item: PermissionService.Item
    @ObservedObject var service: PermissionService
    var compact = false

    private var actionTitle: String {
        if item.state == .restartRequired { return T("重新启动") }
        if compact { return item.prompt != nil && !item.state.isGranted ? T("请求授权") : T("打开设置") }
        return item.state.isGranted ? T("已授权") : T("打开设置")
    }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 14) {
            Image(systemName: item.symbol)
                .font(.system(size: compact ? 14 : 22))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 20 : 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(compact ? .subheadline.weight(.medium) : .body.weight(.medium))
                    if compact {
                        Text(item.state.title).font(.caption2)
                            .foregroundStyle(item.state.isGranted ? Color.green : Color.secondary)
                    } else if item.state.isGranted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                }
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if item.state == .unknown {
                    Text(T("系统没有提供可确认的检测结果，可在系统设置中核对")).font(.caption2).foregroundStyle(.secondary)
                }
                if item.state == .restartRequired {
                    Text(T("系统已允许，重新启动 Aurora 后生效")).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 6)
            Button(actionTitle) {
                if item.state == .restartRequired { service.onRestart?() }
                else if item.state.isGranted { service.openPane(item.pane) }
                else if let prompt = item.prompt { prompt() }
                else { service.openPane(item.pane) }
            }
            .controlSize(compact ? .small : .regular)
            .fixedSize()
            .help(item.state.title)
        }
        .padding(.vertical, compact ? 4 : 8)
        .accessibilityElement(children: .contain)
    }
}
