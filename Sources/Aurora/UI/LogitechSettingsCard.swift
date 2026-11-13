import LogitechPlugin
import SwiftUI

struct LogitechSettingsCard: View {
    @ObservedObject var service: LogitechDeviceService
    var onOpenSetup: (() -> Void)?
    @State private var profileName = ""
    @State private var profileID: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                if service.isEnabled {
                    if let device = service.selectedDevice {
                        deviceLine(device)
                        LogitechHardwareSettings(service: service, device: device)
                        Divider()
                        LogitechButtonsView(service: service, device: device)
                        Divider()
                    } else {
                        offlineHint
                    }
                    if service.selectedDevice != nil || !knownProfiles.isEmpty {
                        profiles
                    }
                    if let message = service.message {
                        Text(T(message))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(T("插件长期启用：鼠标暂时离线不会被关闭，重新连接后自动接管并套用默认方案。"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Logitech", symbol: "computermouse.fill")
            statusBadge
            Spacer(minLength: 4)
            if service.isBusy { ProgressView().controlSize(.small) }
            if onOpenSetup != nil {
                Button(T("向导")) { onOpenSetup?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(T("重新打开罗技鼠标设置向导"))
            }
            Toggle(T("启用"), isOn: Binding(get: { service.isEnabled }, set: { service.setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(T("启用罗技鼠标插件"))
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(service.isOnline ? AuroraTheme.ok : Color.secondary.opacity(0.45))
                .frame(width: 5, height: 5)
            Text(service.isOnline ? T("已连接") : (service.hasKnownDevices ? T("离线") : T("待连接")))
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(service.isOnline ? AuroraTheme.ok : Color.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill((service.isOnline ? AuroraTheme.ok : Color.primary).opacity(0.10)))
    }

    private func deviceLine(_ device: LogitechDevice) -> some View {
        HStack(spacing: 8) {
            if service.devices.count > 1 {
                Picker(T("设备"), selection: $service.selectedID) {
                    ForEach(service.devices) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            } else {
                Text(device.name).font(.system(size: 12, weight: .semibold))
            }
            Spacer(minLength: 4)
            Text(device.transport + (device.battery.map { " · \(T("电量")) \($0)%" } ?? ""))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Button(T("重新连接")) { service.connect() }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AuroraTheme.accent)
                .disabled(service.isBusy)
        }
    }

    private var offlineHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconBadge(symbol: "computermouse", size: 26, style: .tinted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.knownDevices.first?.name ?? T("正在查找罗技设备"))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(T("鼠标暂时不在线，插件保持启用"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(T("重新连接")) { service.connect() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(service.isBusy || !service.isAvailable)
            }
            Text(T("唤醒鼠标或重新插上接收器后会自动连接，不需要再次打开开关。"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 方案

    private var knownProfiles: [LogitechProfile] {
        guard let id = deviceKey else { return service.profiles }
        return service.profiles.filter { $0.deviceID == id }
    }

    /// 在线时用当前设备，离线时回退到上次选中的设备，方案与默认值都能接着改
    private var deviceKey: String? { service.selectedDevice?.id ?? service.selectedID }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(T("鼠标方案")).font(.system(size: 11, weight: .semibold))
                if let defaultID = deviceKey.flatMap({ service.defaultProfileID(for: $0) }),
                   let profile = service.profiles.first(where: { $0.id == defaultID }) {
                    Text(TF("默认 · %@", profile.name))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                }
                Spacer(minLength: 0)
            }

            if !knownProfiles.isEmpty {
                HStack(spacing: 6) {
                    Picker(T("方案"), selection: $profileID) {
                        Text(T("选择方案")).tag(UUID?.none)
                        ForEach(knownProfiles) { profile in
                            Text(profile.name + (service.activeProfile == profile.id ? " ✓" : "")).tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .onAppear(perform: syncSelection)

                    Button(T("应用")) { if let id = profileID { service.applyProfile(id) } }
                        .controlSize(.small)
                        .disabled(profileID == nil || service.isBusy || service.selectedDevice == nil)
                    Button(T("设为默认")) { if let id = profileID { service.setDefaultProfile(id, for: deviceKey) } }
                        .controlSize(.small)
                        .disabled(profileID == nil || service.isBusy
                                  || profileID.map { service.isDefaultProfile($0, deviceID: deviceKey) } == true)
                        .help(T("每次连接这只鼠标时自动应用"))
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .controlSize(.small)
                        .disabled(profileID == nil || service.isBusy)
                        .confirmationDialog(T("删除此鼠标方案？"), isPresented: $confirmingDelete) {
                            Button(T("删除"), role: .destructive) {
                                if let id = profileID { service.deleteProfile(id); profileID = nil }
                            }
                        }
                }
            }

            HStack(spacing: 6) {
                TextField(T("方案名称"), text: $profileName).textFieldStyle(.roundedBorder)
                Button(T("保存当前配置")) {
                    service.saveProfile(name: profileName)
                    profileName = ""
                    syncSelection()
                }
                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty || service.isBusy || service.selectedDevice == nil)
            }
            Text(T("方案保存硬件 DPI、滚轮与罗技按键设置；设为默认后，每次连接自动套用。"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: service.selectedID) { _, _ in profileID = nil }
    }

    private func syncSelection() {
        guard profileID == nil else { return }
        profileID = deviceKey.flatMap { service.defaultProfileID(for: $0) } ?? knownProfiles.first?.id
    }
}
