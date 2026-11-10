import SwiftUI
import LogitechPlugin

struct LogitechButtonsView: View {
    @ObservedObject var service: LogitechDeviceService
    let device: LogitechDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(T("罗技特殊按键")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(T("接管已保存映射")) { service.restoreSavedBindings() }
                    .controlSize(.small).disabled(service.isBusy || (service.bindings[device.id] ?? [:]).isEmpty)
            }
            ForEach(device.buttons.filter(\.canDivert)) { button in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T(button.name)).font(.system(size: 10.5))
                        Text(service.isMappingActive(button.id, deviceID: device.id) ? T(LogitechButtonPolicy.nativeButton(cid: button.id, transport: device.transport) == nil ? "已接管" : "原生事件映射") : T("设备默认行为"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Picker("", selection: Binding(get: { service.bindings[device.id]?[String(button.id)] ?? "none" }, set: {
                        select($0, button: button.id)
                    })) {
                        Text(T("设备默认行为")).tag("none")
                        ForEach(MacroAction.allCases.filter { $0 != .none }) { Text(T($0.title)).tag($0.rawValue) }
                        Text(T("切换罗技方案")).tag("plugin.cycleProfile")
                        Text(T("切换 DPI 档位")).tag("plugin.cycleDPI")
                        Text(T("切换滚轮模式")).tag("plugin.toggleWheel")
                        if let value = service.bindings[device.id]?[String(button.id)], value.hasPrefix("app:") {
                            Text(URL(fileURLWithPath: String(value.dropFirst(4))).deletingPathExtension().lastPathComponent).tag(value)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 180)
                    .disabled(service.isBusy)
                }
            }
            if device.buttons.filter(\.canDivert).isEmpty {
                Text(T("设备未报告可接管的特殊按键")).font(.caption).foregroundStyle(.secondary)
            }
            if device.transport.localizedCaseInsensitiveContains("bluetooth") {
                Text(T("蓝牙中键和侧键使用系统原生事件，优先于下方通用映射；同时连接多只鼠标时，标准按键映射共用。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let last = service.lastButton { Text(T("最近触发") + " · " + T(last)).font(.caption2).foregroundStyle(.secondary) }
            Text(T("仅接管你明确映射的罗技按键；左键、右键保持原样。停用或退出时恢复原上报方式。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func select(_ action: String, button: UInt16) {
        if action == MacroAction.openApplication.rawValue {
            ApplicationPicker.choose { url in
                if let url { service.setBinding(button, action: "app:" + url.path) }
            }
        } else { service.setBinding(button, action: action) }
    }
}
