//  StorageView.swift
//  Aurora — 存储：磁盘占用盘点与安全清理
//
//  这一页刻意不做「一键加速」：先给出一份可核对的账，
//  每一项都能在访达里看见、清理时进废纸篓，随时可以放回。

import AppKit
import SwiftUI

struct StorageView: View {
    @ObservedObject var service: StorageService
    @ObservedObject var permissions: PermissionService
    @ObservedObject var state: AppState

    @ObservedObject var universal: UniversalService
    @State private var tab: StorageTab = .clean
    @State private var confirmingClean = false
    @State private var pendingTrash: StorageBigFile?
    @State private var pendingThin: UniversalApp?
    @State private var confirmingThinAll = false
    @State private var showAllUniversal = false

    enum StorageTab: String, CaseIterable, Identifiable {
        case clean, apps, dev
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clean: return T("清理")
            case .apps: return T("应用管理")
            case .dev: return T("开发")
            }
        }
    }

    init(state: AppState, initialTab: StorageTab = .clean) {
        _tab = State(initialValue: initialTab)
        self.state = state
        service = state.storage
        permissions = state.permissions
        universal = state.universal
    }

    var body: some View {
        VStack(spacing: 12) {
            tabBar
            switch tab {
            case .clean: cleanTab
            case .apps: StorageAppsView(state: state)
            case .dev: StorageDevView(state: state)
            }
        }
        .task {
            service.scanIfNeeded()
            if tab == .clean { universal.scanIfNeeded() }
        }
        .onChange(of: tab) { _, value in
            switch value {
            case .clean: universal.scanIfNeeded()
            case .apps: state.appInventory.scanIfNeeded()
            case .dev: state.devCleanup.scanIfNeeded()
            }
        }
        .confirmationDialog(T("瘦身这个应用？"), isPresented: Binding(
            get: { pendingThin != nil },
            set: { if !$0 { pendingThin = nil } }
        ), presenting: pendingThin) { app in
            Button(T("瘦身")) {
                Task { _ = await universal.thin(app) }
                pendingThin = nil
            }
            Button(T("取消"), role: .cancel) { pendingThin = nil }
        } message: { app in
            Text(TF("%@ 会去掉 Intel 那一份（约 %@），并改用 ad-hoc 签名。这个操作不能撤销，之后如有异常需要重新安装。%@",
                    app.name, Fmt.bytes(UInt64(app.wasted)),
                    app.caution.map { " " + $0 } ?? ""))
        }
        .confirmationDialog(TF("瘦身选中的 %d 个应用？", universal.selection.count),
                            isPresented: $confirmingThinAll) {
            Button(T("开始瘦身"), role: .destructive) {
                Task { await universal.thinSelection() }
            }
            Button(T("取消"), role: .cancel) {}
        } message: {
            Text(TF("会去掉 Intel 那一份（约 %@），并改用 ad-hoc 签名。这个操作不能撤销；正在运行的应用会跳过。",
                    Fmt.bytes(UInt64(universal.selectedBytes))))
        }
        .confirmationDialog(T(service.selection.contains("trash") ? "清空选中的项目？" : "把选中的内容移到废纸篓？"),
                            isPresented: $confirmingClean) {
            Button(T(service.selection.contains("trash") ? "清空" : "移到废纸篓"), role: .destructive) {
                Task { await service.cleanSelection() }
            }
            Button(T("取消"), role: .cancel) {}
        } message: {
            if service.selection.contains("trash") {
                Text(TF("共 %d 项，约 %@。其中废纸篓会被真正清空，里面的项目无法恢复；其余项目会进入废纸篓。",
                        service.selection.count, Fmt.bytes(UInt64(service.selectedBytes))))
            } else {
                Text(TF("共 %d 项，约 %@。全部会进入废纸篓，随时可以放回。",
                        service.selection.count, Fmt.bytes(UInt64(service.selectedBytes))))
            }
        }
        .confirmationDialog(T("把文件移到废纸篓？"), isPresented: Binding(
            get: { pendingTrash != nil },
            set: { if !$0 { pendingTrash = nil } }
        ), presenting: pendingTrash) { file in
            Button(T("移到废纸篓"), role: .destructive) {
                Task { _ = await service.trash(file: file) }
                pendingTrash = nil
            }
            Button(T("取消"), role: .cancel) { pendingTrash = nil }
        } message: { file in
            Text("\(file.name) · \(Fmt.bytes(UInt64(file.bytes)))")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(StorageTab.allCases) { item in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { tab = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tab == item ? Color.primary.opacity(0.10) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var cleanTab: some View {
        AdaptiveCardGrid(
            cards: cards,
            wide: [
                service.cleanableItems.isEmpty && service.isScanning ? AnyView(skeletonCard) : AnyView(cleanCard),
                service.readOnlyItems.isEmpty ? AnyView(emptyReadOnly) : AnyView(readOnlyCard),
                AnyView(universalCard),
                AnyView(bigFilesCard),
                AnyView(toolsCard)
            ]
        )
    }

    private var cards: [AnyView] {
        var list = [AnyView(volumeCard)]
        if !permissions.fullDiskAccess { list.append(AnyView(diskAccessCard)) }
        return list
    }

    /// 没有完全磁盘访问权限时，Library 下的目录量不全，先把原因摆出来
    private var diskAccessCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(AuroraTheme.warn)
                    Text(T("统计结果可能不完整"))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 4)
                    Button(T("打开系统设置")) { permissions.openPane("Privacy_AllFiles") }
                        .controlSize(.mini)
                }
                Text(T("缓存、备份这些目录受系统保护，授权「完全磁盘访问」后才能量出真实大小。"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 磁盘

    private var volumeCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    IconBadge(symbol: "internaldrive.fill", color: AuroraTheme.accent, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.volume?.name ?? T("启动磁盘"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text(volumeSubtitle)
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        service.scan()
                    } label: {
                        HStack(spacing: 4) {
                            if service.isScanning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                            }
                            Text(service.isScanning ? T("扫描中") : T("重新扫描"))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isScanning)
                }

                if let volume = service.volume {
                    UsageBar(fraction: volume.usedFraction)
                    HStack(spacing: 10) {
                        stat(T("已用"), Fmt.bytes(UInt64(volume.used)), tint: volume.usedFraction > 0.9 ? AuroraTheme.danger : nil)
                        stat(T("可用"), Fmt.bytes(UInt64(max(0, volume.free))), tint: AuroraTheme.ok)
                        stat(T("总计"), Fmt.bytes(UInt64(volume.total)))
                    }
                    .font(.system(size: 10, design: .rounded))
                }

                if let status = service.status {
                    Text(status)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if service.isScanning {
                    Text(service.scanningLabel.isEmpty ? T("正在扫描…") : service.scanningLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var volumeSubtitle: String {
        guard let volume = service.volume else { return T("读取中…") }
        let percent = Fmt.percent(volume.usedFraction)
        return TF("已使用 %@ · 共 %@", percent, Fmt.bytes(UInt64(volume.total)))
    }

    private func stat(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint ?? Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(tint!))
                .monospacedDigit()
        }
    }

    // MARK: - 可清理

    private var cleanCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("可以清理"), symbol: "sparkles")
                    Spacer(minLength: 4)
                    if service.totalReclaimable > 0 {
                        Text(Fmt.bytes(UInt64(service.totalReclaimable)))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraTheme.accent)
                            .monospacedDigit()
                    }
                }

                let items = service.cleanableItems
                if items.isEmpty {
                    EmptyHint(symbol: "checkmark.seal", text: service.isScanning ? T("正在统计…") : T("没有发现可清理的内容"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            cleanRow(item)
                            if index < items.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.6).padding(.leading, 30)
                            }
                        }
                    }
                }

                if !items.isEmpty {
                    Divider().opacity(0.5)
                    HStack(spacing: 8) {
                        Text(selectionSummary)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            service.selection = Set(items.filter(\.isCleanable).map(\.id))
                        } label: {
                            Text(T("全选")).font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AuroraTheme.accent)

                        Button {
                            confirmingClean = true
                        } label: {
                            HStack(spacing: 4) {
                                if service.isCleaning { ProgressView().controlSize(.mini) }
                                Text(service.isCleaning
                                     ? T("清理中")
                                     : T(service.selection.contains("trash") ? "清空" : "移到废纸篓"))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(service.selection.isEmpty
                                                       ? AnyShapeStyle(Color.primary.opacity(0.07))
                                                       : AnyShapeStyle(AuroraTheme.accent)))
                            .foregroundStyle(service.selection.isEmpty ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.white))
                        }
                        .buttonStyle(.plain)
                        .disabled(service.selection.isEmpty || service.isCleaning)
                    }
                }
            }
        }
    }

    private var selectionSummary: String {
        if service.isCleaning { return service.cleaningLabel.isEmpty ? T("正在清理…") : service.cleaningLabel }
        guard !service.selection.isEmpty else { return T("勾选要清理的项目") }
        return TF("已选 %d 项 · 约 %@", service.selection.count, Fmt.bytes(UInt64(service.selectedBytes)))
    }

    private func cleanRow(_ item: StorageItem) -> some View {
        let selected = service.selection.contains(item.id)
        return HStack(alignment: .center, spacing: 9) {
            Button {
                if selected { service.selection.remove(item.id) } else { service.selection.insert(item.id) }
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? AuroraTheme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!item.isCleanable)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if item.policy == .confirm {
                        Text(T("需确认"))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(AuroraTheme.warn)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AuroraTheme.warn.opacity(0.14)))
                    }
                }
                Text(item.note ?? item.detail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(item.note == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.warn))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Text(item.measured && item.bytes > 0 ? Fmt.bytes(UInt64(item.bytes)) : "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(item.bytes > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

            Button {
                if let path = item.paths.first { service.reveal(path) }
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(item.paths.isEmpty)
            .help(T("在访达中显示"))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.isCleanable else { return }
            if selected { service.selection.remove(item.id) } else { service.selection.insert(item.id) }
        }
    }

    // MARK: - 通用二进制

    private var universalCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("通用二进制"), symbol: "cpu")
                    Spacer(minLength: 4)
                    if universal.isScanning {
                        ProgressView().controlSize(.mini)
                    } else if universal.totalWasted > 0 {
                        Text(Fmt.bytes(UInt64(universal.thinableBytes)))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraTheme.accent)
                            .monospacedDigit()
                    }
                }
                Text(T("同时带 Intel 与 Apple Silicon 两份的 App。这台机器用不到 Intel 那一份；瘦身会改成 ad-hoc 签名，不能撤销。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if universal.apps.isEmpty {
                    EmptyHint(symbol: universal.isScanning ? "hourglass" : "cpu",
                              text: universal.isScanning ? T("正在扫描应用…") : T("没有发现同时带两种架构的应用"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleUniversalApps.enumerated()), id: \.element.id) { index, app in
                            universalRow(app)
                            if index < visibleUniversalApps.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.6).padding(.leading, 40)
                            }
                        }
                    }

                    if universal.apps.count > universalRowLimit {
                        Button {
                            withAnimation(.smooth(duration: 0.18)) { showAllUniversal.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(showAllUniversal
                                     ? T("收起")
                                     : TF("展开其余 %d 个", universal.apps.count - universalRowLimit))
                                Image(systemName: showAllUniversal ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 7, weight: .semibold))
                            }
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }

                    if !universal.selectableApps.isEmpty {
                        universalFooter
                    }
                }
            }
        }
    }

    /// 勾选 + 批量瘦身：和上面清理卡片一致的交互
    private var universalFooter: some View {
        HStack(spacing: 9) {
            Button {
                universal.toggleSelectAll()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: universal.allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(universal.allSelected ? AuroraTheme.accent : Color.secondary.opacity(0.5))
                    Text(T("全选"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(universal.isBatching)

            if universal.isBatching {
                Text(TF("正在瘦身 %d / %d", universal.batchDone ?? 0, universal.batchTotal))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !universal.selection.isEmpty {
                Text(TF("已选 %d 项 · 约 %@", universal.selectedApps.count,
                        Fmt.bytes(UInt64(universal.selectedBytes))))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Button {
                confirmingThinAll = true
            } label: {
                Text(universal.isBatching ? T("处理中…") : T("瘦身所选"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(universal.selection.isEmpty ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.white))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(universal.selection.isEmpty
                                       ? AnyShapeStyle(Color.primary.opacity(0.07))
                                       : AnyShapeStyle(AuroraTheme.accentGradient))
                    )
            }
            .buttonStyle(.plain)
            .disabled(universal.selection.isEmpty || universal.isBatching || universal.thinningID != nil)
        }
        .padding(.top, 2)
    }

    private var universalRowLimit: Int { showAllUniversal ? universal.apps.count : 8 }

    private var visibleUniversalApps: [UniversalApp] {
        Array(universal.apps.prefix(universalRowLimit))
    }

    private func universalRow(_ app: UniversalApp) -> some View {
        let selected = universal.selection.contains(app.id)
        let selectable = app.blockReason == nil
        return HStack(spacing: 8) {
            Button {
                universal.toggleSelection(app)
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? AuroraTheme.accent : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(!selectable || universal.isBatching)
            .opacity(selectable ? 1 : 0.35)

            // 和「应用管理」一致：用系统真实图标，一眼能对上是谁
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 20, height: 20)
                .opacity(selectable ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(app.name).font(.system(size: 10.5)).lineLimit(1)
                Text(app.blockReason ?? app.caution ?? TF("%d 个二进制带两份架构", app.binaries.count))
                    .font(.system(size: 8.5))
                    .foregroundStyle(app.blockReason == nil && app.caution == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Fmt.bytes(UInt64(app.wasted)))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if selectable {
                Button {
                    pendingThin = app
                } label: {
                    Text(app.isRunning ? T("运行中") : T("瘦身"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(app.isRunning ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.accent))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(app.isRunning || universal.thinningID != nil || universal.isBatching)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - 只读盘点

    private var emptyReadOnly: some View { EmptyView() }

    private var readOnlyCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("只读盘点"), symbol: "eye")
                VStack(spacing: 0) {
                    let items = service.readOnlyItems
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(item.title).font(.system(size: 10.5))
                                Text(item.note ?? item.detail)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if item.bytes > 0 {
                                Text(Fmt.bytes(UInt64(item.bytes)))
                                    .font(.system(size: 9.5, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            if let path = item.paths.first {
                                Button { service.reveal(path) } label: {
                                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(T("在访达中显示"))
                            }
                        }
                        .padding(.vertical, 5)
                        if index < items.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.6).padding(.leading, 25)
                        }
                    }
                }
                Text(T("这些内容 Aurora 不会代你删除，确认不再需要后请手动处理。"))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 大文件

    private var bigFilesCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("大文件"), symbol: "doc.zipper")
                    Spacer(minLength: 4)
                    Text(T("下载、桌面、文档、影片里超过 1GB 的文件"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                if service.bigFiles.isEmpty {
                    EmptyHint(symbol: service.isFindingBigFiles || service.isScanning ? "hourglass" : "hand.thumbsup",
                              text: service.isFindingBigFiles || service.isScanning ? T("正在查找…") : T("没有发现超过 1GB 的文件"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(service.bigFiles.enumerated()), id: \.element.id) { index, file in
                            HStack(spacing: 9) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1.5) {
                                    Text(file.name)
                                        .font(.system(size: 10.5))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(Fmt.relative(file.modified) + " · " + parentFolder(file.path))
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(Fmt.bytes(UInt64(file.bytes)))
                                    .font(.system(size: 9.5, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button { service.reveal(file.path) } label: {
                                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                Button { pendingTrash = file } label: {
                                    Image(systemName: "trash").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 5)
                            if index < service.bigFiles.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.6).padding(.leading, 25)
                            }
                        }
                    }
                }
            }
        }
    }

    private func parentFolder(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if folder.hasPrefix(home) { folder = "~" + folder.dropFirst(home.count) }
        return folder
    }

    // MARK: - 外部工具

    private var toolsCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: T("命令行工具"), symbol: "terminal")
                HStack(spacing: 6) {
                    ForEach(["brew", "docker", "mole", "ncdu", "mas"], id: \.self) { tool in
                        toolChip(tool)
                    }
                    Spacer(minLength: 0)
                }
                // 讲清楚「用系统命令」还是「自带命令」，避免以为 Aurora 打包了第三方 CLI
                Text(T("统计与清理用的是系统自带的 du / find / lipo / codesign，Aurora 里没有打包任何第三方命令行工具；上面这几个只是检测你装没装。"))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if service.tools["mole"] == true {
                    HStack(spacing: 6) {
                        Text(T("Mole 已安装，可以交给它做深度清理"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button(T("在终端运行")) {
                            CommandRunner.openInTerminal("mole clean")
                        }
                        .controlSize(.mini)
                    }
                } else {
                    Text(T("装好 Mole / ncdu 这类 CLI 后，Aurora 会把入口放在这里；不会代替你执行破坏性命令。"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func toolChip(_ tool: String) -> some View {
        let installed = service.tools[tool] == true
        return HStack(spacing: 3.5) {
            Circle()
                .fill(installed ? AuroraTheme.ok : Color.secondary.opacity(0.35))
                .frame(width: 4.5, height: 4.5)
            Text(tool)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(installed ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    private var skeletonCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("可以清理"), symbol: "sparkles")
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 9) {
                        Circle().fill(Color.primary.opacity(0.08)).frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: 110, height: 9)
                        Spacer()
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: 44, height: 9)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

// MARK: - 占用条

private struct UsageBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(fraction > 0.9
                          ? LinearGradient(colors: [AuroraTheme.warn, AuroraTheme.danger], startPoint: .leading, endPoint: .trailing)
                          : AuroraTheme.accentGradient)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}
