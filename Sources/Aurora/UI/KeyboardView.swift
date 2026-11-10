//  KeyboardView.swift
//  Aurora — 键盘

import SwiftUI

struct KeyboardView: View {
    @ObservedObject var service: KeyboardService
    @ObservedObject var devices: HIDDeviceService
    @ObservedObject var permissions: PermissionService
    @ObservedObject var state: AppState

    init(state: AppState) {
        self.state = state
        self.service = state.keyboard
        self.devices = state.hid
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            if !permissions.accessibility { permissionCard }
            devicesCard
            typeCard
            testCard
            cleanCard
            repeatCard
        }
        .onAppear { service.reloadTypes() }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "lock.shield.fill", color: AuroraTheme.warn, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("清洁键盘需要辅助功能权限"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(T("锁定键盘需要拦截系统键盘事件；按键测试不需要权限"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(T("前往授权")) { service.onRequestPermission?() }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    Button(T("打开系统设置")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    // MARK: - 设备

    private var devicesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel(text: T("键盘设备"), symbol: "keyboard")
                    Spacer()
                    Text(TF("%d 个", devices.keyboards.count))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Button {
                        devices.refresh()
                        service.reloadTypes()
                        state.showToast(T("已重新扫描设备"), symbol: "arrow.clockwise")
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(4)
                            .background(Circle().fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }

                if devices.keyboards.isEmpty {
                    EmptyHint(symbol: "keyboard", text: T("未检测到键盘"))
                } else {
                    VStack(spacing: 6) {
                        ForEach(devices.keyboards) { device in
                            deviceRow(device)
                        }
                    }
                }

                Text(T("类型来自系统记录；内建键盘由硬件决定，外接键盘写入后重新连接即可生效。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceRow(_ device: HIDDevice) -> some View {
        HStack(spacing: 9) {
            IconBadge(symbol: device.transportSymbol, size: 30, style: .tinted)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(device.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    if device.isBuiltIn {
                        badge(T("内建"), color: .secondary)
                    }
                    if let battery = device.battery {
                        HStack(spacing: 2) {
                            Image(systemName: batterySymbol(battery))
                                .font(.system(size: 7.5))
                            Text("\(battery)%")
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(battery <= 20 ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(.secondary))
                    }
                }
                HStack(spacing: 4) {
                    Text(device.transportLabel)
                    if device.vendorID > 0 {
                        Text("·")
                        Text(device.vendorLabel)
                    }
                    Text("·")
                    Text(service.storedType(for: device).title)
                }
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if device.canSetType {
                Menu {
                    ForEach(KeyboardType.allCases) { type in
                        Button {
                            service.applyType(type, for: device)
                        } label: {
                            if service.storedType(for: device) == type {
                                Label(type.title, systemImage: "checkmark")
                            } else {
                                Text("\(type.title) · \(type.detail)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(service.storedType(for: device).title)
                            .font(.system(size: 9.5, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 6.5, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(service.storedType(for: device).title)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .help(T("内建键盘的类型由硬件决定，无需设置"))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private func batterySymbol(_ value: Int) -> String {
        switch value {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - 类型说明

    private var typeCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("键盘类型"), symbol: "rectangle.split.3x1")
                typeRow("ANSI", detail: T("美式 · 长条回车"))
                typeRow("ISO", detail: T("欧式 · 大 L 回车"))
                typeRow("JIS", detail: T("日式 · 多两个键"))
                Text(T("如果键位与键帽对不上（例如回车键形状不对），切换类型即可修正；需要管理员授权写入系统记录。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func typeRow(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .frame(width: 30, alignment: .leading)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 按键测试

    private var testCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "keyboard.badge.ellipsis", size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("按键与组合键测试"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("在独立窗口里高亮按键，识别 ⌃⌥⇧⌘ 组合"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(T("开始测试")) {
                        state.dismissMainPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            KeyTestWindowController.shared.show()
                        }
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                }
            }
        }
    }

    // MARK: - 清洁

    private var cleanCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "sparkles", color: AuroraTheme.ok, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("清洁键盘"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("暂时忽略所有按键，擦拭时不会误操作"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(service.cleanMode ? T("解锁") : T("锁定")) {
                        if service.cleanMode {
                            service.stopCleaning()
                        } else {
                            if !service.startCleaning() { /* 权限提示已由 service 负责 */ }
                        }
                    }
                    .buttonStyle(SoftButtonStyle(prominent: !service.cleanMode))
                }

                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(AuroraTheme.warn)
                    Text(T("锁定后鼠标仍可用：按 ⌃⌥⌘K、点悬浮窗按钮，或等 5 分钟都会自动解锁。"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 重复

    private var repeatCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(text: T("按键重复"), symbol: "arrow.triangle.2.circlepath")

                SliderRow(
                    symbol: "hourglass",
                    title: T("重复延迟"),
                    value: $service.keyRepeatDelay,
                    range: 10...60,
                    displayText: "\(Int(service.keyRepeatDelay * 15)) ms"
                )

                SliderRow(
                    symbol: "forward.fill",
                    title: T("重复速度"),
                    value: Binding(
                        get: { 13 - service.keyRepeatRate },
                        set: { service.keyRepeatRate = 13 - $0 }
                    ),
                    range: 1...12,
                    displayText: TF("%d 次/秒", max(1, Int((60 / max(service.keyRepeatRate, 1)).rounded())))
                )

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    Image(systemName: "fn")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("F1–F12 直接作为功能键"))
                            .font(.system(size: 11, weight: .medium))
                        Text(T("关闭时优先调节亮度、音量等系统功能"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $service.functionKeysFirst)
                }

                Text(T("重复速率写入系统偏好，对所有 App 生效。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
