import SwiftUI

struct WelcomePermissions: View {
    @ObservedObject var state: AppState
    @ObservedObject var service: PermissionService
    let selection: Set<AuroraModule>

    init(state: AppState, selection: Set<AuroraModule>) {
        self.state = state
        service = state.permissions
        self.selection = selection
    }

    private var items: [PermissionService.Item] {
        service.items.filter { item in
            switch item.id {
            case "accessibility": return selection.contains(.pointer) || selection.contains(.clipboard)
            case "screen", "input": return selection.contains(.pointer)
            case "camera", "microphone": return selection.contains(.recorder)
            // 通知与模块无关：更新、录制完成、截图保存都会用到，默认展示
            case "notifications": return true
            case "disk": return selection.contains(.ai)
            default: return false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            PermissionRow(item: item, service: service)
                            if index < items.count - 1 { Divider().padding(.leading, 44) }
                        }
                        if items.isEmpty { Text(T("所选模块无需额外系统权限。")) .padding() }
                    }
                    .padding(.horizontal, 8)
                }
                if selection.contains(.menu) {
                    HStack {
                        Label(T("Finder 右键菜单"), systemImage: "folder")
                        Spacer()
                        Button(T("打开扩展管理")) { state.finderExt.openExtensionSettings() }
                    }
                    Text(T("在文件提供程序或按应用列表中查找 Aurora。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if selection.contains(.audio) {
                    Text(T("按应用音量会在首次调节时请求系统音频录制权限。设备切换和系统音量无需此权限。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(T("重新检测权限")) { service.recheck() }.disabled(service.isChecking)
                    if service.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let error = service.checkError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text(T("授权后自动复查。如系统要求重新启动，可在这里重启 Aurora 并继续设置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            // 通知授权状态来自 UNUserNotificationCenter，进页面时刷新一次
            NotificationService.shared.refresh()
            service.refresh()
        }
    }
}
