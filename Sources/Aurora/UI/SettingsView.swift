import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var tab = Tab.general

    private enum Tab: String, CaseIterable {
        case general = "通用"
        case modules = "模块"
        case permissions = "权限"
        case about = "关于"
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker(T("设置"), selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { section in
                    Text(T(section.rawValue)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .padding(.horizontal, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .general: GeneralPreferences(settings: state.settings)
                    case .modules: SettingsModulesView(settings: state.settings)
                    case .permissions:
                        SettingsPermissionsView(service: state.permissions, openWelcome: state.openWelcome)
                    case .about:
                        AppAboutView(settings: state.settings, state: state)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
            }
            .id(tab)
        }
        .id(state.languageToken)
    }
}

private struct GeneralPreferences: View {
    @ObservedObject var settings: SettingsService
    @AppStorage("settings.confirmBeforeQuit") private var confirmBeforeQuit = true

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(T("语言与外观"), systemImage: "paintpalette")
                    .font(.headline)
                SettingRow(title: T("语言")) {
                    Picker(T("语言"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language)
                        }
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("外观")).font(.subheadline)
                    SettingsAppearancePicker(selection: $settings.appearance)
                }
            }
        }
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(T("启动与退出"), systemImage: "power").font(.headline)
                SettingRow(title: T("开机自动启动"), subtitle: settings.launchAtLoginError == nil ? T("登录时自动打开 Aurora") : nil) {
                    Toggle(T("开机自动启动"), isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin))
                        .labelsHidden()
                }
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(AuroraTheme.warn).textSelection(.enabled)
                }
                Divider()
                SettingRow(title: T("退出前确认"), subtitle: T("从主面板退出 Aurora 时询问")) {
                    Toggle(T("退出前确认"), isOn: $confirmBeforeQuit).labelsHidden()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .onAppear { settings.refreshLaunchAtLogin() }
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
