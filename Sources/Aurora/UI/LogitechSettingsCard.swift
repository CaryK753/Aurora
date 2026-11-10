import SwiftUI
import LogitechPlugin

struct LogitechSettingsCard: View {
    @ObservedObject var service: LogitechDeviceService
    @State private var profileName = ""
    @State private var profileID: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        Group {
          if service.isAvailable { GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "Logitech", symbol: "computermouse.fill")
                    Text(T("独立鼠标插件")).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if service.isBusy { ProgressView().controlSize(.small) }
                    Toggle(T("启用"), isOn: Binding(get: { service.isEnabled }, set: { service.setEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if service.isEnabled {
                    HStack {
                        if service.devices.count > 1 {
                            Picker(T("设备"), selection: $service.selectedID) {
                                ForEach(service.devices) { Text($0.name).tag(Optional($0.id)) }
                            }
                        } else { Text(service.selectedDevice?.name ?? T("正在查找罗技设备")).font(.callout.weight(.medium)) }
                        Spacer()
                        Button(T("重新连接")) { service.connect() }.disabled(service.isBusy)
                            .buttonStyle(SoftButtonStyle())
                    }
                    if let device = service.selectedDevice {
                        Text(device.transport + (device.battery.map { " · \(T("电量")) \($0)%" } ?? ""))
                            .font(.caption2).foregroundStyle(.secondary)
                        LogitechHardwareSettings(service: service, device: device)
                        Divider()
                        LogitechButtonsView(service: service, device: device)
                        Divider()
                        profiles(device)
                    }
                    if let message = service.message {
                        Text(T(message)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        }
        }
    }

    private func profiles(_ device: LogitechDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("鼠标方案")).font(.system(size: 11, weight: .semibold))
            let profiles = service.profiles.filter { $0.deviceID == device.id }
            if !profiles.isEmpty {
                HStack {
                    Picker(T("方案"), selection: $profileID) {
                        Text(T("选择方案")).tag(UUID?.none)
                        ForEach(profiles) { profile in
                            Text(profile.name + (service.activeProfile == profile.id ? " ✓" : "")).tag(Optional(profile.id))
                        }
                    }.labelsHidden()
                    Button(T("应用")) { if let id = profileID { service.applyProfile(id) } }
                        .disabled(profileID == nil || service.isBusy)
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .disabled(profileID == nil || service.isBusy)
                        .confirmationDialog(T("删除此鼠标方案？"), isPresented: $confirmingDelete) {
                            Button(T("删除"), role: .destructive) {
                                if let id = profileID { service.deleteProfile(id); profileID = nil }
                            }
                        }
                }
            }
            HStack {
                TextField(T("方案名称"), text: $profileName).textFieldStyle(.roundedBorder)
                Button(T("保存当前配置")) { service.saveProfile(name: profileName); profileName = "" }
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty || service.isBusy)
            }
            Text(T("方案保存硬件 DPI、滚轮与罗技按键设置；断线后不会擅自覆盖设备设置。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: device.id) { _, _ in profileID = nil }
    }
}
