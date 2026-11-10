//  SettingsView.swift
//  Aurora — 设置与信息

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var permissions: PermissionService
    @ObservedObject var state: AppState
    @State private var confirmBeforeQuit = AuroraAlert.confirmBeforeQuit

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(T("欢迎与权限设置")) { state.openWelcome() }
                .buttonStyle(SoftButtonStyle())
            generalCard
            modulesCard
            permissionCard
            aboutCard
        }
    }

    // MARK: - 通用

    private var generalCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: T("通用"), symbol: "slider.horizontal.3")

                HStack(spacing: 6) {
                    Text(T("语言"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    ForEach(AppLanguage.allCases) { language in
                        chip(
                            title: language.localizedTitle,
                            active: settings.language == language
                        ) {
                            settings.language = language
                            state.showToast(T("语言"), symbol: "globe")
                        }
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 6) {
                    Text(T("外观"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    ForEach(AppAppearance.allCases) { appearance in
                        appearanceChip(appearance)
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    Image(systemName: "power.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("开机自动启动"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(settings.launchAtLoginError ?? T("登录时自动打开 Aurora"))
                            .font(.system(size: 9))
                            .foregroundStyle(settings.launchAtLoginError == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.warn))
                            .lineLimit(2)
                    }
                    Spacer()
                    AuroraToggle(isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    Image(systemName: "escape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("退出前确认"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("点右上角电源按钮时先询问，弹窗里可勾选不再询问"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    AuroraToggle(isOn: Binding(
                        get: { confirmBeforeQuit },
                        set: { value in
                            confirmBeforeQuit = value
                            AuroraAlert.confirmBeforeQuit = value
                        }
                    ))
                }
            }
        }
    }

    // MARK: - 模块

    private var modulesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: T("启用的模块"), symbol: "square.grid.2x2")
                    Spacer()
                    Text(T("关闭后隐藏模块，并停止鼠标、剪贴板、键盘清洁、节能和音量接管"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 2) {
                    ForEach(AuroraModule.allCases.filter(\.isToggleable)) { module in
                        HStack(spacing: 9) {
                            Image(systemName: module.symbol)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(T(module.title))
                                .font(.system(size: 11))
                            Spacer()
                            AuroraToggle(isOn: Binding(
                                get: { settings.isEnabled(module) },
                                set: { enabled in
                                    settings.setModule(module, enabled: enabled)
                                    if !enabled, state.module == module { state.select(.overview) }
                                    state.showToast(
                                        enabled ? T("模块已显示") : T("模块已在侧边栏隐藏"),
                                        symbol: module.symbol
                                    )
                                }
                            ))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - 权限

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("权限"), symbol: "hand.raised")
                    Spacer()
                    Button {
                        permissions.recheck()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 8, weight: .bold))
                            Text(T("重新检测"))
                                .font(.system(size: 8.5))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }

                if permissions.isChecking { ProgressView().controlSize(.small) }
                if let error = permissions.checkError {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                }
                let list = permissions.items
                ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                    permissionRow(item)
                    if index < list.count - 1 {
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6).padding(.leading, 24)
                    }
                }

                Text(T("状态会自动复查；显示「重启生效」时，请重新启动 Aurora。无需重启 Mac。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(_ item: PermissionService.Item) -> some View {
        PermissionRow(item: item, service: permissions, compact: true)
    }

    // MARK: - 关于

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("关于"), symbol: "info.circle")

                AppAboutView(settings: settings, state: state)

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                Text(T("参考项目"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                + Text(" LinearMouse · MonitorControl · Stats · Mos · RClick · Maccy · KeepingYouAwake · switchaudio-osx · CodexBar")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func appearanceChip(_ appearance: AppAppearance) -> some View {
        let active = settings.appearance == appearance
        return Button {
            settings.appearance = appearance
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: appearance.symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(appearance.title)
                    .font(.system(size: 9, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
            }
            .overlay {
                Capsule().strokeBorder(active ? Color.white.opacity(0.25) : Color.primary.opacity(0.10), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
                }
        }
        .buttonStyle(.plain)
    }
}

extension AppLanguage {
    var localizedTitle: String {
        switch self {
        case .system: return T("跟随系统")
        case .zhHans: return T("简体中文")
        case .en: return "English"
        }
    }
}
