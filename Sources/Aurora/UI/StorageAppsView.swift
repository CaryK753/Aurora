//  StorageAppsView.swift
//  Aurora — 存储 › 应用：列出已安装应用，卸载时连残留一起收
//
//  卸载一律走废纸篓；残留只按 bundle id 与同名目录匹配，误伤概率尽量压到最低。

import AppKit
import SwiftUI

struct StorageAppsView: View {
    @ObservedObject var inventory: AppInventoryService
    @State private var query = ""
    @State private var target: InstalledApp?

    init(state: AppState) {
        inventory = state.appInventory
    }

    private var filtered: [InstalledApp] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return inventory.apps }
        return inventory.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            searchCard
            listCard
            Text(T("卸载会把应用本体和勾选的残留一起移到废纸篓，登录项与后台服务需要重启后完全失效。"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .task { inventory.scanIfNeeded() }
        .sheet(item: $target) { app in
            StorageUninstallSheet(inventory: inventory, app: app) { target = nil }
        }
    }

    private var searchCard: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(T("搜索应用或 bundle id"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if inventory.isScanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(TF("%d 个应用", filtered.count))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if inventory.isScanning, !inventory.progress.isEmpty {
                Text(inventory.progress)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private var listCard: some View {
        GlassCard(padding: 12) {
            if inventory.isScanning && inventory.apps.isEmpty {
                EmptyHint(symbol: "hourglass", text: T("正在读取应用…"))
            } else if filtered.isEmpty {
                EmptyHint(symbol: "app.dashed", text: T("没有匹配的应用"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, app in
                        row(app)
                        if index < filtered.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 0.6).padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    private func row(_ app: InstalledApp) -> some View {
        Button {
            guard inventory.isUninstallable(app) else { return }
            target = app
        } label: {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(app.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        if app.isRunning {
                            Text(T("运行中"))
                                .font(.system(size: 7.5))
                                .foregroundStyle(AuroraTheme.ok)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(AuroraTheme.ok.opacity(0.14)))
                        }
                    }
                    Text("\(app.version) · \(app.bundleID)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let used = app.lastUsed {
                    Text(Fmt.relative(used))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Text(app.measured ? Fmt.bytes(UInt64(app.bytes)) : "—")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!inventory.isUninstallable(app))
    }
}

// MARK: - 卸载确认

struct StorageUninstallSheet: View {
    @ObservedObject var inventory: AppInventoryService
    let app: InstalledApp
    var onClose: () -> Void

    @State private var leftovers: [AppLeftover] = []
    @State private var loading = true
    @State private var working = false
    @State private var error: String?

    private var selectedBytes: Int64 {
        app.bytes + leftovers.filter(\.selected).reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            leftovers = await inventory.leftovers(for: app)
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 15, weight: .semibold))
                Text("\(app.version) · \(app.bundleID)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(text: T("一起清理的残留"), symbol: "trash")
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if loading {
                EmptyHint(symbol: "hourglass", text: T("正在查找相关文件…"))
            } else if leftovers.isEmpty {
                EmptyHint(symbol: "checkmark.seal", text: T("没有找到相关残留"))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(leftovers.enumerated()), id: \.element.id) { index, item in
                            leftoverRow(index, item)
                            if index < leftovers.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 0.6).padding(.leading, 30)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }

            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(AuroraTheme.danger).padding(.horizontal, 18)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func leftoverRow(_ index: Int, _ item: AppLeftover) -> some View {
        HStack(spacing: 9) {
            Button {
                leftovers[index].selected.toggle()
            } label: {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.selected ? AuroraTheme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.category).font(.system(size: 10, weight: .medium))
                Text(item.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(Fmt.bytes(UInt64(item.bytes)))
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(TF("合计 %@", Fmt.bytes(UInt64(selectedBytes))))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button(T("取消")) { onClose() }
            Button(T("卸载")) { uninstall() }
                .buttonStyle(.borderedProminent)
                .tint(AuroraTheme.danger)
                .disabled(working)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func uninstall() {
        working = true
        error = nil
        Task {
            if let failure = await inventory.uninstall(app: app, leftovers: leftovers) {
                error = failure
                working = false
            } else {
                working = false
                onClose()
            }
        }
    }
}
