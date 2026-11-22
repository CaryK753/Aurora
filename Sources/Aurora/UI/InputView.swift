//  InputView.swift
//  Aurora — 输入法

import AppKit
import SwiftUI

struct InputView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var service: InputMethodService
    @ObservedObject private var snippets: SnippetService
    @ObservedObject private var health: IMEHealthService
    @ObservedObject private var permissions: PermissionService

    @State private var newAbbr = ""
    @State private var newText = ""
    @State private var newDomain = ""

    init(state: AppState) {
        self.state = state
        self.service = state.input
        self.snippets = state.snippets
        self.health = state.imeHealth
        self.permissions = state.permissions
    }

    var body: some View {
        AdaptiveCardGrid(cards: [
            permissions.accessibility ? nil : AnyView(permissionCard),
            AnyView(indicatorCard),
            AnyView(habitCard),
            AnyView(LanguageCoachCard(state: state, service: state.languageTyping)),
            AnyView(autoSwitchCard),
            AnyView(snippetCard),
            AnyView(healthCard),
        ].compactMap { $0 })
        .onAppear {
            service.refreshSources()
            health.sample()
        }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "lock.shield.fill", color: AuroraTheme.warn, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("输入法增强需要辅助功能权限"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(T("读光标位置、浏览器地址栏与拦截按键都需要授权"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(T("前往授权")) { state.permissions.requestAccessibility() }
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

    // MARK: - 指示器

    private var indicatorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "character.cursor.ibeam", size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("输入法指示器"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("切换输入法时在光标旁短暂显示当前状态"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $service.indicatorEnabled)
                }

                HStack(spacing: 10) {
                    IndicatorBubbleView(label: service.currentSource?.shortLabel ?? "A")
                        .frame(width: 46, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.currentSource?.name ?? T("当前输入法"))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                        Text(T("现在使用的输入法"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if service.sources.count > 1 {
                        Button(T("切换")) {
                            // 在两个常用输入源之间来回切，方便验证指示器
                            let target = service.sources.first(where: { $0.id != service.currentSource?.id })
                            if let target { service.selectSource(target) }
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - 输入习惯
    private var habitCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("输入习惯"), symbol: "keyboard.badge.ellipsis")

                HStack(spacing: 9) {
                    IconBadge(symbol: "shift", size: 24, style: .tinted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("单击 Shift 切换中英文"))
                            .font(.system(size: 11, weight: .medium))
                        Text(T("和 Windows 上搜狗的习惯一致；按住打字、配合鼠标都不受影响"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $service.shiftSwitchEnabled)
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    IconBadge(symbol: "capslock", size: 24, style: .tinted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("大写锁定键只锁大写"))
                            .font(.system(size: 11, weight: .medium))
                        Text(T("关掉系统的「使用大写锁定键切换 ABC」，按 Caps Lock 就是大写"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: Binding(
                        get: { service.capsLockLocksUppercase },
                        set: { service.setCapsLockLocksUppercase($0) }
                    ))
                }

                Text(T("个别输入法（搜狗、微信、百度等）有自己的 Caps Lock 设置，需要在它们自己的偏好里一并关掉。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 自动切换

    private var autoSwitchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "arrow.triangle.swap", size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("自动切换输入法"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("按应用与网站切换，终端、代码托管站自动用英文"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $service.autoSwitchEnabled)
                }

                if !service.autoSwitchEnabled {
                    Text(T("开启后切到指定应用或网站时，输入法会自动换成你设定的那一款。"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // 应用规则
                    HStack {
                        SectionLabel(text: T("应用规则"), symbol: "square.grid.2x2")
                        Spacer()
                        Button(T("添加应用")) {
                            ApplicationPicker.choose { url in
                                guard let url else { return }
                                service.addAppRule(at: url)
                            }
                        }
                        .buttonStyle(SoftButtonStyle())
                        .font(.system(size: 9.5))
                    }

                    if service.appRules.isEmpty {
                        EmptyHint(symbol: "square.grid.2x2", text: T("还没有应用规则"))
                    } else {
                        VStack(spacing: 6) {
                            ForEach(service.appRules) { rule in
                                appRuleRow(rule)
                            }
                        }
                    }

                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                    // 网站规则
                    HStack {
                        SectionLabel(text: T("网站规则"), symbol: "safari")
                        Spacer()
                    }
                    ForEach(service.siteRules) { rule in
                        siteRuleRow(rule)
                    }
                    HStack(spacing: 6) {
                        TextField(T("域名，如 github.com"), text: $newDomain)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            }
                            .onSubmit(addSiteRule)
                        Button(T("添加")) { addSiteRule() }
                            .buttonStyle(SoftButtonStyle(prominent: true))
                            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(T("支持 Safari、Chrome、Edge、Arc、Brave、Firefox 等；填写域名即可，子域名自动匹配。"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func appRuleRow(_ rule: IMAppRule) -> some View {
        HStack(spacing: 9) {
            AppIconView(bundleID: rule.bundleID, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(TF("切到时使用 %@", rule.sourceName))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            sourceMenu(selectedID: rule.sourceID) { source in
                service.updateAppRule(bundleID: rule.bundleID, source: source)
            }
            Button {
                service.removeAppRule(bundleID: rule.bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private func siteRuleRow(_ rule: IMSiteRule) -> some View {
        HStack(spacing: 9) {
            IconBadge(symbol: "globe", size: 24, style: .tinted)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.domain)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(TF("使用 %@", rule.sourceName))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            sourceMenu(selectedID: rule.sourceID) { source in
                service.updateSiteRule(domain: rule.domain, source: source)
            }
            Button {
                service.removeSiteRule(domain: rule.domain)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    /// 选目标输入法的菜单
    private func sourceMenu(selectedID: String, action: @escaping (IMSource) -> Void) -> some View {
        Menu {
            ForEach(service.sources) { source in
                Button {
                    action(source)
                } label: {
                    if source.id == selectedID {
                        Label(source.name, systemImage: "checkmark")
                    } else {
                        Text(source.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(service.sources.first(where: { $0.id == selectedID })?.shortLabel ?? "A")
                    .font(.system(size: 9.5, weight: .semibold))
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
    }

    private func addSiteRule() {
        guard let domain = InputRuleDomain.normalize(newDomain) else {
            state.showToast(T("请输入有效的域名或网页地址"), symbol: "exclamationmark.triangle")
            return
        }
        guard let source = service.currentSource ?? service.sources.first else {
            state.showToast(T("没有可用的输入法"), symbol: "exclamationmark.triangle")
            return
        }
        if service.addSiteRule(domain: domain, source: source) {
            newDomain = ""
        } else {
            state.showToast(T("域名已存在"), symbol: "exclamationmark.triangle")
        }
    }

    // MARK: - 自定义短语

    private var snippetCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "text.and.command.minus", size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("自定义短语"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("打出缩写和空格，自动展开成完整内容"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $snippets.enabled)
                }

                if snippets.enabled && !snippets.isActive {
                    Label(T("短语监听未运行，请检查输入监控和辅助功能权限后重新开启"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9)).foregroundStyle(AuroraTheme.warn)
                }
                if !snippets.enabled {
                    Text(T("开启后输入「缩写 + 空格 / 回车」就会替换成展开内容，密码框里不会生效。"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(snippets.snippets) { snippet in
                            snippetRow(snippet)
                        }
                    }

                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            TextField(T("缩写"), text: $newAbbr)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10.5, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                }
                                .frame(width: 96)
                            TextField(T("展开内容"), text: $newText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10.5))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                }
                                .onSubmit(addSnippet)
                            Button(T("添加")) { addSnippet() }
                                .buttonStyle(SoftButtonStyle(prominent: true))
                                .disabled(newAbbr.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        HStack(spacing: 6) {
                            Button {
                                snippets.importSystemReplacements()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 8, weight: .semibold))
                                    Text(T("导入系统文本替换"))
                                        .font(.system(size: 9.5, weight: .medium))
                                }
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                            .help(T("把「系统设置 › 键盘 › 文本替换」里的短语导入进来"))

                            Text(TF("系统里有 %d 条", SnippetService.systemReplacements().count))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 9) {
            Text(snippet.abbr)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
            Text(snippet.text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            AuroraToggle(isOn: Binding(
                get: { snippet.enabled },
                set: { snippets.setEnabled(snippet, $0) }
            ))
            Button {
                snippets.remove(snippet)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private func addSnippet() {
        let abbr = newAbbr
        let text = newText
        guard !abbr.isEmpty, !text.isEmpty else { return }
        guard snippets.add(abbr: abbr, text: text) else { return }
        newAbbr = ""
        newText = ""
    }

    // MARK: - 输入法健康

    private var healthCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "stethoscope", color: AuroraTheme.ok, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("输入法健康"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("盯着容易卡死的输入法进程，异常时一键修复"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $health.monitoringEnabled)
                }

                VStack(spacing: 6) {
                    ForEach(health.processes) { status in
                        healthRow(status)
                    }
                }

                if !health.events.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(health.events.prefix(3)) { event in
                            HStack(spacing: 5) {
                                Image(systemName: event.repaired ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(event.repaired ? AuroraTheme.ok : AuroraTheme.warn)
                                Text(TF("%@ · %@", event.processName, event.reason))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(event.date.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Text(T("打字卡顿、字符一个个蹦出来，多半是这几个进程卡死了；修复会安全终止它们，系统会自动重启对应服务。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func healthRow(_ status: IMEProcessStatus) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(!status.running ? AuroraTheme.ok.opacity(0.4)
                      : status.stuck ? AuroraTheme.warn
                      : AuroraTheme.ok)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.label)
                    .font(.system(size: 11, weight: .medium))
                Text(status.running
                     ? TF("PID %d · 内存 %.0f MB · CPU %.0f%%", status.pid ?? 0, status.memoryMB, status.cpuPercent)
                     : T("未在运行"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if status.stuck {
                Button(T("一键修复")) { health.repair(status) }
                    .disabled(health.repairingIDs.contains(status.id))
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }
}

// MARK: - App 图标

private struct AppIconView: View {
    let bundleID: String
    let size: CGFloat

    /// bundleID → 图标缓存
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        if let icon = Self.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            IconBadge(symbol: "app.dashed", size: size, style: .tinted)
        }
    }

    private static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}
