//  WallpaperView.swift
//  Aurora — 动态壁纸：独立覆盖页（壁纸库 / 自动切换 / 显示器）

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum WallpaperTab: String, CaseIterable, Identifiable {
    case library, rules, displays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return T("壁纸库")
        case .rules: return T("自动切换")
        case .displays: return T("显示器")
        }
    }

    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .rules: return "wand.and.stars"
        case .displays: return "display"
        }
    }
}

enum WallpaperFilter: String, CaseIterable, Identifiable {
    case all, motion, still

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return T("全部")
        case .motion: return T("动态")
        case .still: return T("静态")
        }
    }
}

struct WallpaperView: View {
    @ObservedObject var state: AppState
    @ObservedObject var service: WallpaperService
    @ObservedObject var library: WallpaperLibrary

    @State private var tab: WallpaperTab = .library
    @State private var filter: WallpaperFilter = .all
    @State private var query = ""
    @State private var dropActive = false
    @State private var detail: WallpaperItem?
    @State private var showDownload = false
    @State private var downloadText = ""
    @State private var isDownloading = false
    @State private var showSystem = true

    init(state: AppState) {
        self.state = state
        self.service = state.wallpaper
        self.library = state.wallpapers
        // 开发调试：AURORA_WALLPAPER_TAB=rules/displays 直接落在对应标签
        let tabEnv = ProcessInfo.processInfo.environment["AURORA_WALLPAPER_TAB"] ?? ""
        _tab = State(initialValue: tabEnv == "rules" ? .rules : (tabEnv == "displays" ? .displays : .library))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            tabBar
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.6)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .library:
                        libraryContent
                    case .rules:
                        WallpaperRulePanel(service: service, library: library, state: state)
                    case .displays:
                        WallpaperDisplayPanel(service: service, library: library, state: state)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.never)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.smooth(duration: 0.2)) { dropActive = targeted }
        }
        .overlay {
            if dropActive { dropOverlay }
        }
        .sheet(item: $detail) { item in
            WallpaperDetailSheet(
                item: item,
                library: library,
                service: service,
                state: state,
                onPreview: { state.previewWallpaper(item, fill: service.config.fill) }
            )
        }
        .sheet(isPresented: $showDownload) { downloadSheet }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.26)) { state.showWallpaper = false }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(T("返回桌面"))

            VStack(alignment: .leading, spacing: 1) {
                Text(T("动态壁纸"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(service.config.enabled ? service.activeSummary : T("未启用，桌面保持系统壁纸"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if service.config.rule.kind == .random, let text = service.nextRotateText, service.config.enabled {
                Button {
                    service.rotateNow()
                    state.showToast(T("已换一张"), symbol: "shuffle")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shuffle").font(.system(size: 8, weight: .bold))
                        Text(text).font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(T("立即换一张"))
            }

            AuroraToggle(isOn: Binding(
                get: { service.config.enabled },
                set: { on in
                    service.setEnabled(on)
                    state.showToast(
                        on ? T("动态壁纸已开启") : T("已恢复系统壁纸"),
                        symbol: on ? "sparkles" : "pause.circle"
                    )
                }
            ))
        }
        // 固定窗口下左上角是红绿灯，顶栏内容往右让
        .padding(.leading, state.isPinned ? 78 : 16)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(WallpaperTab.allCases) { item in
                Button {
                    withAnimation(.smooth(duration: 0.24)) { tab = item }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 9, weight: .semibold))
                        Text(item.title).font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(tab == item ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        Capsule().fill(tab == item ? Color.primary.opacity(0.09) : Color.clear)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 壁纸库

    private var filteredItems: [WallpaperItem] {
        var list = library.items
        switch filter {
        case .all: break
        case .motion: list = list.filter(\.kind.isMotion)
        case .still: list = list.filter { $0.kind == .image }
        }
        let keyword = query.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
        }
        return list.sorted { $0.addedAt > $1.addedAt }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            libraryToolbar

            if library.items.isEmpty {
                emptyLibrary
            } else {
                sectionHeader(T("我的壁纸"), count: filteredItems.count)
                if filteredItems.isEmpty {
                    Text(T("没有符合条件的壁纸"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 12)
                } else {
                    grid(filteredItems)
                }
            }

            systemSection

            sourcesSection
        }
    }

    private var libraryToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(WallpaperFilter.allCases) { item in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { filter = item }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(filter == item ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background {
                                Capsule().fill(
                                    filter == item
                                        ? AnyShapeStyle(AuroraTheme.accentGradient)
                                        : AnyShapeStyle(Color.primary.opacity(0.06))
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 6)

                searchField
            }

            HStack(spacing: 6) {
                Button {
                    chooseFiles()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 8.5, weight: .bold))
                        Text(T("导入")).font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button {
                    chooseFolder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 8.5, weight: .bold))
                        Text(T("文件夹")).font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Button {
                    showDownload = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 8.5, weight: .bold))
                        Text(T("下载")).font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Text(TF("%d 动态 · %d 静态", library.motionCount, library.stillCount))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
            TextField(T("搜索"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 9.5))
                .frame(width: 74)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            SectionLabel(text: title)
            Text("\(count)")
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
    }

    private func grid(_ items: [WallpaperItem]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 118, maximum: 210), spacing: 10)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(items) { item in
                card(item)
            }
        }
    }

    private func card(_ item: WallpaperItem) -> some View {
        let active = service.current.values.contains(item.id)
        return WallpaperCardView(
            item: item,
            thumb: library.thumbnails[item.id],
            isActive: active,
            isSystem: item.isSystem,
            onPreview: { state.previewWallpaper(item, fill: service.config.fill) },
            onUse: {
                service.useAsWallpaper(item)
                state.showToast(TF("已设为壁纸 · %@", item.name), symbol: "checkmark.circle.fill")
            },
            onInfo: { detail = item },
            onDelete: item.isSystem ? nil : {
                library.remove(item)
                state.showToast(TF("已移除 %@", item.name), symbol: "trash")
            },
            onAdopt: nil
        )
        .onAppear { library.requestThumbnail(item) }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(AuroraTheme.accent.opacity(0.7))
            Text(T("把视频、GIF 或图片拖进来"))
                .font(.system(size: 12, weight: .semibold))
            Text(T("支持 mp4 / mov / gif / heic / jpg / png，导入后就能设成桌面壁纸、按时间或外观自动切换。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(T("选择文件")) { chooseFiles() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                Button(T("选择文件夹")) { chooseFolder() }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(dropActive ? 0.08 : 0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            dropActive ? AuroraTheme.accent : Color.primary.opacity(0.14),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: T("Apple 壁纸库"))
                Text("\(library.systemItems.count)")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    library.scanSystemWallpapers()
                    state.showToast(T("已刷新 Apple 壁纸"), symbol: "arrow.clockwise")
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                if !library.hiddenSystemIDs.isEmpty {
                    Button(T("恢复移除的")) { library.restoreSystemWallpapers() }
                        .buttonStyle(.plain)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(AuroraTheme.accent)
                }
                Button {
                    withAnimation(.smooth(duration: 0.2)) { showSystem.toggle() }
                } label: {
                    Image(systemName: showSystem ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if showSystem {
                if library.systemMotionCount == 0 {
                    // Apple 的航拍动态壁纸要先在系统屏保里选过才会缓存到本机
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(T("想用 Apple 航拍视频？先在系统屏幕保护程序里挑一个，下载后会自动出现在这里"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Button(T("打开系统设置")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(AuroraTheme.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    }
                }
                if library.systemItems.isEmpty {
                    Text(T("系统里没有找到可用的自带壁纸"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 8)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(library.systemItems) { item in
                            systemCard(item)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func systemCard(_ item: WallpaperItem) -> some View {
        WallpaperCardView(
            item: item,
            thumb: library.thumbnails[item.id],
            isActive: service.current.values.contains(item.id),
            isSystem: true,
            onPreview: { state.previewWallpaper(item, fill: service.config.fill) },
            onUse: {
                service.useAsWallpaper(item)
                state.showToast(TF("已设为壁纸 · %@", item.name), symbol: "checkmark.circle.fill")
            },
            onInfo: { detail = item },
            onDelete: nil,
            onAdopt: {
                if let adopted = library.adopt(item) {
                    service.useAsWallpaper(adopted)
                    state.showToast(TF("已加入壁纸库 · %@", adopted.name), symbol: "tray.and.arrow.down.fill")
                }
            }
        )
        .onAppear { library.requestThumbnail(item) }
    }

    // MARK: - 外部壁纸库

    /// 第三方壁纸站：统一入口，用户自己浏览 / 下载后用「下载」粘贴直链入库
    private static let externalSources: [(name: String, desc: String, tag: String, symbol: String, url: String)] = [
        ("Unsplash", "顶级摄影社区，免署名可商用", "图片", "camera.on.rectangle", "https://unsplash.com"),
        ("Pixabay", "图片和视频都有，免费商用免署名", "图片+视频", "photo.on.rectangle.angled", "https://pixabay.com"),
        ("Wallhaven", "壁纸垂直站，可按分辨率与比例筛选", "图片", "square.grid.3x3", "https://wallhaven.cc"),
        ("NASA", "太空摄影与视频，公有领域随便用", "图片+视频", "globe.americas.fill", "https://images.nasa.gov"),
        ("Coverr", "免费短视频，适合剪成循环的动态壁纸", "视频", "video.fill", "https://coverr.co"),
    ]

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: T("外部壁纸库"))
                Text(T("去这些站挑好后复制直链，用上面的「下载」加入本机壁纸库"))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Self.externalSources, id: \.url) { source in
                    sourceCard(source)
                }
            }
        }
        .padding(.top, 4)
    }

    private func sourceCard(_ source: (name: String, desc: String, tag: String, symbol: String, url: String)) -> some View {
        Button {
            if let url = URL(string: source.url) {
                NSWorkspace.shared.open(url)
                state.showToast(TF("已在浏览器打开 %@", source.name), symbol: "safari")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: source.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AuroraTheme.accent)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AuroraTheme.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(source.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(source.tag)
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Text(source.desc)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(TF("在浏览器打开 %@", source.name))
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AuroraTheme.accent.opacity(0.10))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text(T("松手导入到壁纸库"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(AuroraTheme.accent)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: - 下载

    private var downloadSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconBadge(symbol: "arrow.down.circle.fill", color: AuroraTheme.accent, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(T("从链接下载壁纸"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(T("粘贴图片或视频的直链，下载完成后自动加入壁纸库"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            TextField("https://…", text: $downloadText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            HStack(spacing: 8) {
                Spacer()
                Button(T("取消")) { showDownload = false }
                    .buttonStyle(SoftButtonStyle())
                Button(isDownloading ? T("下载中…") : T("下载")) { startDownload() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(isDownloading || downloadText.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func startDownload() {
        guard let url = URL(string: downloadText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            state.showToast(T("链接格式不对"), symbol: "exclamationmark.triangle")
            return
        }
        isDownloading = true
        Task {
            defer { isDownloading = false }
            do {
                let (temp, _) = try await URLSession.shared.download(from: url)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                let result = library.importFiles([destination])
                if result.added > 0 {
                    showDownload = false
                    downloadText = ""
                    state.showToast(result.message, symbol: "arrow.down.circle.fill")
                } else {
                    state.showToast(T("下载的内容不是可用的壁纸格式"), symbol: "exclamationmark.triangle")
                }
            } catch {
                state.showToast(TF("下载失败：%@", error.localizedDescription), symbol: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - 导入

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = T("选择图片、视频或 GIF")
        if panel.runModal() == .OK {
            let result = library.importFiles(panel.urls)
            state.showToast(result.message, symbol: "tray.and.arrow.down.fill")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = T("把整个文件夹里的壁纸导入")
        if panel.runModal() == .OK, let url = panel.url {
            let result = library.importFiles([url])
            state.showToast(result.message, symbol: "folder.fill")
        }
    }

    private func handleDrop(_ urls: [URL]) {
        let result = library.importFiles(urls)
        state.showToast(result.message, symbol: "tray.and.arrow.down.fill")
    }
}
