//  ContextMenuView.swift
//  Aurora — Finder 右键：自定义动作（FinderSync 扩展）+ 系统菜单项开关

import SwiftUI
import AppKit

struct ContextMenuView: View {
    @ObservedObject var service: ContextMenuService
    @ObservedObject var finder: FinderExtensionService
    @ObservedObject var state: AppState

    @State private var filter: ContextMenuItem.Kind?
    @State private var query = ""
    @State private var hoveredID: String?
    @State private var editingID: String?
    @State private var draftTitle = ""
    @State private var draftArgument = ""

    init(state: AppState) {
        self.state = state
        self.service = state.contextMenu
        self.finder = state.finderExt
    }

    var body: some View {
        VStack(spacing: 10) {
            finderCard
            systemCard
            footer
        }
    }

    // MARK: - Finder 扩展（真正的自定义右键）

    private var finderCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AuroraTheme.accent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("Finder 右键"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(statusText)
                            .font(.system(size: 9))
                            .foregroundStyle(finder.isEnabled ? Color.secondary : AuroraTheme.warn)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        finder.repairRegistration()
                        finder.restartFinder()
                        state.showToast(T("已重新登记扩展，正在重启访达"), symbol: "arrow.triangle.2.circlepath")
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(T("重新向系统登记扩展并重启访达"))
                    statusPill
                }

                if !finder.isEnabled {
                    Button {
                        finder.openExtensionSettings()
                        state.showToast(T("在「登录项与扩展 › 文件提供程序」中找到 Aurora，也可切换为「按应用」查找"), symbol: "switch.2")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9, weight: .bold))
                            Text(T("去启用扩展"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(AuroraTheme.accentGradient))
                    }
                    .buttonStyle(.plain)
                } else if !finder.didLoad {
                    Button {
                        finder.restartFinder()
                        state.showToast(T("访达已重启，右键试试"), symbol: "checkmark.circle.fill")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                            Text(T("重启访达让它加载扩展"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(AuroraTheme.accentGradient))
                    }
                    .buttonStyle(.plain)
                }

                if finder.actions.isEmpty {
                    Text(T("还没有自定义项，下面加一个试试"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(finder.actions.enumerated()), id: \.element.id) { index, action in
                            actionRow(action)
                            if index < finder.actions.count - 1 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 0.6)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                }

                addRow
            }
        }
    }

    private var statusText: String {
        guard finder.isEnabled else { return T("扩展未启用，需在系统设置里勾选") }
        if !finder.didLoad { return T("已启用，Finder 还没加载它：右键一次或重启访达") }
        return TF("%d 项已生效，右键即可看到", finder.enabledCount)
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(finder.isEnabled ? AuroraTheme.ok : AuroraTheme.warn)
                .frame(width: 5, height: 5)
            Text(finder.isEnabled ? T("已启用") : T("未启用"))
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(finder.isEnabled ? AuroraTheme.ok : AuroraTheme.warn)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((finder.isEnabled ? AuroraTheme.ok : AuroraTheme.warn).opacity(0.12)))
    }

    private func actionRow(_ action: FinderAction) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: action.kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(action.enabled ? AuroraTheme.accent : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AuroraTheme.accent.opacity(action.enabled ? 0.14 : 0.05))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle(for: action))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if hoveredID == action.id {
                    Button { beginEdit(action) } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)

                    Button { finder.remove(action.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                AuroraToggle(isOn: Binding(
                    get: { action.enabled },
                    set: { _ in finder.toggle(action.id) }
                ))
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredID = action.id }
                else if hoveredID == action.id { hoveredID = nil }
            }

            if editingID == action.id {
                editor(for: action)
            }
        }
    }

    private func subtitle(for action: FinderAction) -> String {
        action.argument.isEmpty ? action.kind.hint : "\(action.kind.title) · \(action.argument)"
    }

    private func beginEdit(_ action: FinderAction) {
        editingID = action.id
        draftTitle = action.title
        draftArgument = action.argument
    }

    private func editor(for action: FinderAction) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField(T("名称"), text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.055)))

                if let placeholder = action.kind.argumentPlaceholder {
                    TextField(placeholder, text: $draftArgument)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, design: action.kind == .runCommand ? .monospaced : .default))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.055)))
                }

                if action.kind == .openWithApp {
                    Button(T("选择")) { pickApplication() }
                        .buttonStyle(SoftButtonStyle())
                }
            }

            HStack(spacing: 6) {
                Text(action.kind.argumentPlaceholder == nil
                     ? T("这个动作不需要额外参数")
                     : T("留空则使用默认值"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(T("取消")) { editingID = nil }
                    .buttonStyle(SoftButtonStyle())
                Button(T("保存")) { commitEdit(action) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 6)
    }

    private func commitEdit(_ action: FinderAction) {
        var updated = action
        updated.title = draftTitle.trimmingCharacters(in: .whitespaces).isEmpty ? action.kind.title : draftTitle
        updated.argument = draftArgument
        finder.update(updated)
        editingID = nil
        state.showToast(T("右键项已更新"), symbol: "checkmark.circle.fill")
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draftArgument = url.path
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(FinderAction.Kind.allCases) { kind in
                    Button {
                        finder.add(kind)
                        state.showToast(TF("已添加：%@", kind.title), symbol: "plus.circle.fill")
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text(T("添加右键项"))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(AuroraTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text(T("添加后立即生效，无需重启 Finder"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 系统右键项

    private var filtered: [ContextMenuItem] {
        service.items.filter { item in
            (filter == nil || item.kind == filter!)
                && (query.isEmpty
                    || item.title.localizedCaseInsensitiveContains(query)
                    || item.provider.localizedCaseInsensitiveContains(query))
        }
    }

    private var systemCard: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("系统菜单项"), symbol: "menubar.rectangle")
                    Spacer()
                    Text(service.isScanning
                         ? T("正在扫描…")
                         : TF("已启用 %d / %d", service.items.filter(\.isEnabled).count, service.items.count))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Button {
                        service.refreshFinderNow()
                        state.showToast(T("访达已刷新"), symbol: "checkmark.circle.fill")
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(T("重启访达以应用改动"))
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField(T("搜索菜单项"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

                HStack(spacing: 5) {
                    chip(title: "\(T("全部")) \(service.items.count)", active: filter == nil) { filter = nil }
                    ForEach(ContextMenuItem.Kind.allCases, id: \.self) { kind in
                        let count = service.items.filter { $0.kind == kind }.count
                        if count > 0 {
                            chip(title: "\(kind.title) \(count)", active: filter == kind) { filter = kind }
                        }
                    }
                    Spacer(minLength: 0)
                }

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if filtered.isEmpty {
                            Text(service.isScanning ? T("正在扫描…") : T("没有匹配的菜单项"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                        } else {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                systemRow(item)
                                if index < filtered.count - 1 {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.055))
                                        .frame(height: 0.6)
                                        .padding(.leading, 30)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 208)
                .padding(.bottom, 2)
            }
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background {
                    if active {
                        Capsule().fill(AuroraTheme.accentGradient)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.05))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func systemRow(_ item: ContextMenuItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(item.kind == .service ? Color.secondary : AuroraTheme.accent)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 0.5) {
                Text(item.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Text(item.provider)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            AuroraToggle(
                isOn: Binding(
                    get: { item.isEnabled },
                    set: { newValue in
                        service.setEnabled(newValue, for: item.id)
                        state.showToast(
                            "\(item.title) \(newValue ? "已启用" : "已关闭")",
                            symbol: newValue ? "checkmark.circle.fill" : "minus.circle.fill"
                        )
                    }
                )
            )
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(T("自定义项由 Aurora 的 Finder 扩展注入；系统菜单项改完会自动重启访达。"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}
