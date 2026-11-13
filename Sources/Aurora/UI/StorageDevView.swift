//  StorageDevView.swift
//  Aurora — 存储 › 开发：语言包管理器缓存 + 项目构建产物
//
//  缓存删了会自动重新下载；node_modules / target 这类删了要重新构建，所以分开展示。

import AppKit
import SwiftUI

struct StorageDevView: View {
    @ObservedObject var dev: DevCleanupService
    @State private var confirming = false

    init(state: AppState) {
        dev = state.devCleanup
    }

    private var selectedCount: Int { dev.selection.count + dev.projectSelection.count }

    var body: some View {
        VStack(spacing: 12) {
            summaryCard
            cacheCard
            projectsCard
            Text(T("清理都走废纸篓：缓存删了下次会自动下载，构建产物删了需要重新编译一次。"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .task { dev.scanIfNeeded() }
        .confirmationDialog(T("把选中的开发缓存移到废纸篓？"), isPresented: $confirming) {
            Button(T("移到废纸篓"), role: .destructive) {
                Task { await dev.cleanSelection() }
            }
            Button(T("取消"), role: .cancel) {}
        } message: {
            Text(TF("共 %d 项，约 %@。node_modules / target 这类目录会整个移走。",
                    selectedCount, Fmt.bytes(UInt64(dev.selectedBytes))))
        }
    }

    private var summaryCard: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 11) {
                IconBadge(symbol: "hammer.fill", color: AuroraTheme.accent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("开发缓存与构建产物"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(TF("缓存 %@ · 项目产物 %@", Fmt.bytes(UInt64(dev.totalCache)), Fmt.bytes(UInt64(dev.totalProjects))))
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                if dev.isScanning || dev.isFindingProjects {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await dev.scan() }
                    } label: {
                        Text(T("重新扫描"))
                            .font(.system(size: 10))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var cacheCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("包管理器缓存"), symbol: "shippingbox")
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(UInt64(dev.totalCache)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AuroraTheme.accent)
                        .monospacedDigit()
                }
                let items = dev.categories.filter { $0.available }
                if items.isEmpty {
                    EmptyHint(symbol: "checkmark.seal", text: T("没有检测到开发工具缓存"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            cacheRow(item)
                            if index < items.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 0.6).padding(.leading, 26)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cacheRow(_ item: DevCategory) -> some View {
        let selected = dev.selection.contains(item.id)
        return HStack(spacing: 9) {
            Button {
                if selected { dev.selection.remove(item.id) } else { dev.selection.insert(item.id) }
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AuroraTheme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(item.bytes == 0)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.title).font(.system(size: 10.5))
                Text(item.detail).font(.system(size: 8.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(item.measured ? Fmt.bytes(UInt64(item.bytes)) : "—")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                if let path = item.paths.first { dev.reveal(path) }
            } label: {
                Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.bytes > 0 else { return }
            if selected { dev.selection.remove(item.id) } else { dev.selection.insert(item.id) }
        }
    }

    private var projectsCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("项目构建产物"), symbol: "folder.badge.gearshape")
                    Spacer(minLength: 4)
                    if dev.isFindingProjects {
                        ProgressView().controlSize(.mini)
                    } else if dev.totalProjects > 0 {
                        Text(Fmt.bytes(UInt64(dev.totalProjects)))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraTheme.accent)
                            .monospacedDigit()
                    }
                }
                if dev.projects.isEmpty {
                    EmptyHint(symbol: dev.isFindingProjects ? "hourglass" : "checkmark.seal",
                              text: dev.isFindingProjects ? T("正在扫描项目目录…") : T("没有发现 node_modules / target 这类目录"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(dev.projects.enumerated()), id: \.element.id) { index, project in
                            projectRow(project)
                            if index < dev.projects.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 0.6).padding(.leading, 26)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        dev.projectSelection = Set(dev.projects.map(\.id))
                    } label: {
                        Text(T("全选产物")).font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AuroraTheme.accent)
                    Button {
                        dev.selection = Set(dev.categories.filter { $0.bytes > 0 }.map(\.id))
                    } label: {
                        Text(T("全选缓存")).font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AuroraTheme.accent)
                    Spacer(minLength: 4)
                    if selectedCount > 0 {
                        Text(Fmt.bytes(UInt64(dev.selectedBytes)))
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button {
                        confirming = true
                    } label: {
                        Text(dev.isCleaning ? T("清理中") : T("清理"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selectedCount == 0 ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.white))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(selectedCount == 0 ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(AuroraTheme.accent)))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedCount == 0 || dev.isCleaning)
                }
                .padding(.top, 2)
            }
        }
    }

    private func projectRow(_ project: DevProject) -> some View {
        let selected = dev.projectSelection.contains(project.id)
        return HStack(spacing: 9) {
            Button {
                if selected { dev.projectSelection.remove(project.id) } else { dev.projectSelection.insert(project.id) }
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AuroraTheme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(project.project).font(.system(size: 10.5)).lineLimit(1)
                Text(project.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(project.kind)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            Text(Fmt.bytes(UInt64(project.bytes)))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { dev.reveal(project.path) } label: {
                Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if selected { dev.projectSelection.remove(project.id) } else { dev.projectSelection.insert(project.id) }
        }
    }
}
