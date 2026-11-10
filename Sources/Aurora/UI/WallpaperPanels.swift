//  WallpaperPanels.swift
//  Aurora — 动态壁纸：自动切换规则 + 显示器独立设置

import SwiftUI

// MARK: - 自动切换

struct WallpaperRulePanel: View {
    @ObservedObject var service: WallpaperService
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var state: AppState

    @State private var rule: WallpaperRule

    init(service: WallpaperService, library: WallpaperLibrary, state: AppState) {
        self.service = service
        self.library = library
        self.state = state
        _rule = State(initialValue: service.config.rule)
    }

    var body: some View {
        VStack(spacing: 12) {
            kindCard
            editorCard
            fillCard
            tipRow
        }
        .onChange(of: rule) { _, new in
            service.setRule(new)
        }
        .onChange(of: service.config.rule) { _, new in
            if new != rule { rule = new }
        }
    }

    // MARK: 规则类型

    private var kindCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: T("自动切换"), symbol: "wand.and.stars")

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(WallpaperRuleKind.allCases) { kind in
                        kindTile(kind)
                    }
                }
            }
        }
    }

    private func kindTile(_ kind: WallpaperRuleKind) -> some View {
        let selected = rule.kind == kind
        return Button {
            var updated = rule
            updated.kind = kind
            withAnimation(.smooth(duration: 0.24)) { rule = updated }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(kind.detail)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AuroraTheme.accent.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? AuroraTheme.accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 各规则编辑器

    @ViewBuilder
    private var editorCard: some View {
        switch rule.kind {
        case .single: singleEditor
        case .appearance: appearanceEditor
        case .schedule: scheduleEditor
        case .random: randomEditor
        }
    }

    private func itemMenu(_ current: String, allowNone: Bool = false, onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            if allowNone {
                Button(T("不指定")) { onSelect("") }
            }
            if !library.items.isEmpty {
                Divider()
                ForEach(library.items) { item in
                    Button(item.name) { onSelect(item.id) }
                }
            }
            if !library.systemItems.isEmpty {
                Divider()
                ForEach(library.systemItems) { item in
                    Button(TF("Apple · %@", item.name)) { onSelect(item.id) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "photo")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(library.item(id: current)?.name ?? T("未指定"))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func thumbDot(_ item: WallpaperItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.3))
            if let thumb = library.thumbnails[item.id] {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 18, height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onAppear { library.requestThumbnail(item) }
    }

    private var singleEditor: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("固定一张"), symbol: "pin.fill")
                    Spacer()
                    if let item = service.previewResolution() {
                        thumbDot(item)
                        Text(item.name)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    Text(T("壁纸"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    itemMenu(rule.single, allowNone: true) { rule.single = $0 }
                }
                Text(T("在壁纸库里双击任意一张也能立刻应用。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var appearanceEditor: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("跟随外观"), symbol: "circle.lefthalf.filled")
                    Spacer()
                    Text(service.isDarkAppearance ? T("当前系统 · 深色") : T("当前系统 · 浅色"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(service.isDarkAppearance ? AnyShapeStyle(.secondary) : AnyShapeStyle(AuroraTheme.warn.opacity(0.9)))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                appearanceRow(
                    title: T("浅色模式用"),
                    symbol: "sun.max.fill",
                    tint: AuroraTheme.warn,
                    current: rule.light
                ) { rule.light = $0 }

                appearanceRow(
                    title: T("深色模式用"),
                    symbol: "moon.stars.fill",
                    tint: AuroraTheme.accent,
                    current: rule.dark
                ) { rule.dark = $0 }

                Text(T("系统切换浅色 / 深色时，壁纸会以柔和的交叉淡入切换。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func appearanceRow(
        title: String,
        symbol: String,
        tint: Color,
        current: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint.opacity(0.9))
                .frame(width: 14)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
            Spacer(minLength: 6)
            itemMenu(current, allowNone: true, onSelect: onSelect)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private var scheduleEditor: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("按时间"), symbol: "clock.fill")
                    Spacer()
                    if let item = service.previewResolution() {
                        Text(TF("现在 · %@", item.name))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(AuroraTheme.accent)
                            .lineLimit(1)
                    }
                }

                if rule.slots.isEmpty {
                    Text(T("加几个时间点，比如 07:00 日出、12:00 正午、19:00 夜晚，到点自动换。"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 4) {
                        ForEach(rule.slots.sorted { $0.minutes < $1.minutes }) { slot in
                            slotRow(slot)
                        }
                    }
                }

                HStack {
                    Button {
                        var updated = rule
                        let latest = updated.slots.map(\.minutes).max() ?? -180
                        let next = latest + 180
                        updated.slots.append(
                            WallpaperSlot(minutes: min(next, 23 * 60 + 59), itemID: updated.slots.last?.itemID ?? "")
                        )
                        withAnimation(.smooth(duration: 0.24)) { rule = updated }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                            Text(T("添加时间点")).font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }

    private func updateSlot(_ id: String, _ mutate: (inout WallpaperSlot) -> Void) {
        var updated = rule
        guard let index = updated.slots.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated.slots[index])
        rule = updated
    }

    private func slotRow(_ slot: WallpaperSlot) -> some View {
        let active = service.previewResolution()?.id == slot.itemID
        return HStack(spacing: 6) {
            slotTimePickers(slot)
            itemMenu(slot.itemID, allowNone: true) { value in
                updateSlot(slot.id) { $0.itemID = value }
            }
            Button {
                var updated = rule
                updated.slots.removeAll { $0.id == slot.id }
                withAnimation(.smooth(duration: 0.2)) { rule = updated }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(T("删除这个时间点"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? AuroraTheme.accent.opacity(0.08) : Color.primary.opacity(0.035))
        }
    }

    private func slotTimePickers(_ slot: WallpaperSlot) -> some View {
        HStack(spacing: 3) {
            Picker("", selection: Binding(
                get: { slot.hour },
                set: { value in updateSlot(slot.id) { $0.hour = value } }
            )) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 48)

            Text(":")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)

            Picker("", selection: Binding(
                get: { slot.minute },
                set: { value in updateSlot(slot.id) { $0.minute = value } }
            )) {
                ForEach(stride(from: 0, to: 60, by: 5).map(\.self), id: \.self) {
                    Text(String(format: "%02d", $0)).tag($0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 48)
        }
        .controlSize(.mini)
    }

    private var randomEditor: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("随机轮播"), symbol: "shuffle")
                    Spacer()
                    if let text = service.nextRotateText {
                        Text(text)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(T("来源"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { rule.randomSource },
                        set: { rule.randomSource = $0 }
                    )) {
                        ForEach(WallpaperRandomSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }

                if rule.randomSource == .folder {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(library.randomFolders, id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(AuroraTheme.accent)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 10))
                                Text(T("已选中"))
                                    .font(.system(size: 7.5, weight: .medium))
                                    .foregroundStyle(rule.randomFolder == path ? AnyShapeStyle(AuroraTheme.ok) : AnyShapeStyle(.tertiary))
                                Spacer()
                                if rule.randomFolder != path {
                                    Button {
                                        var updated = rule
                                        updated.randomFolder = path
                                        rule = updated
                                    } label: {
                                        Text(T("使用"))
                                            .font(.system(size: 8, weight: .medium))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button {
                                    library.removeRandomFolder(path)
                                    if rule.randomFolder == path {
                                        var updated = rule
                                        updated.randomFolder = ""
                                        rule = updated
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(rule.randomFolder == path ? AuroraTheme.accent.opacity(0.08) : Color.primary.opacity(0.035))
                            }
                        }

                        HStack(spacing: 6) {
                            Button(T("添加文件夹")) {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    library.addRandomFolder(url)
                                    var updated = rule
                                    updated.randomFolder = url.path
                                    rule = updated
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AuroraTheme.accent)
                            if library.randomFolders.isEmpty {
                                Text(T("选一个装满壁纸的文件夹，里面静态动态都会随机"))
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text(T("间隔"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { rule.randomInterval },
                        set: { rule.randomInterval = max(1, $0) }
                    )) {
                        ForEach([5, 15, 30, 60, 120, 360, 1440], id: \.self) { minutes in
                            Text(intervalText(minutes)).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                    Spacer()
                    Button {
                        service.rotateNow()
                        state.showToast(T("已换一张"), symbol: "shuffle")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shuffle").font(.system(size: 8, weight: .bold))
                            Text(T("换一张")).font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }

                Text(T("随机轮播会记住当前屏的壁纸，不会原地反复横跳。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func intervalText(_ minutes: Int) -> String {
        if minutes >= 1440 { return T("每天") }
        if minutes >= 60 { return TF("每 %d 小时", minutes / 60) }
        return TF("每 %d 分钟", minutes)
    }

    // MARK: 填充方式

    private var fillCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: T("填充方式"), symbol: "rectangle.compress.vertical")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72, maximum: 110), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(WallpaperFill.allCases) { fill in
                        fillTile(fill)
                    }
                }
            }
        }
    }

    private func fillTile(_ fill: WallpaperFill) -> some View {
        let selected = service.config.fill == fill
        return Button {
            service.setFill(fill)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: fill.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(.secondary))
                Text(fill.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AuroraTheme.accent.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? AuroraTheme.accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fill.detail)
    }

    private var tipRow: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 9))
                .foregroundStyle(AuroraTheme.warn.opacity(0.9))
            Text(T("规则对全部显示器生效；要给某块屏单独安排，去「显示器」页。"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 显示器

struct WallpaperDisplayPanel: View {
    @ObservedObject var service: WallpaperService
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var state: AppState

    init(service: WallpaperService, library: WallpaperLibrary, state: AppState) {
        self.service = service
        self.library = library
        self.state = state
    }

    var body: some View {
        VStack(spacing: 12) {
            if service.displays.isEmpty {
                GlassCard {
                    Text(T("没有检测到显示器"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(service.displays) { display in
                    displayCard(display)
                }
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(T("每个显示器可以单独指定壁纸与填充方式；同一显示器的各个 macOS 工作空间会跟随该显示器的设置。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
    }

    private func displayCard(_ display: WallpaperService.DisplayInfo) -> some View {
        let overridden = service.isOverridden(display.id)
        let current = service.currentItem(for: display.id)
        return GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "display", color: overridden ? AuroraTheme.accent : AuroraTheme.ok, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(display.name)
                                .font(.system(size: 11.5, weight: .semibold))
                            if display.isMain {
                                Text(T("主屏"))
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(AuroraTheme.accent))
                            }
                        }
                        Text("\(display.pixelText) · " + (service.config.enabled ? T("显示中") : T("未启用")))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let current {
                        HStack(spacing: 5) {
                            displayThumb(current)
                            Text(current.name)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 8) {
                    Text(T("这台屏用"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    displayMenu(display)
                    Spacer(minLength: 6)
                    fillMenu(display)
                }
            }
        }
    }

    private func displayThumb(_ item: WallpaperItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.3))
            if let thumb = library.thumbnails[item.id] {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 28, height: 17)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { library.requestThumbnail(item) }
    }

    private func displayMenu(_ display: WallpaperService.DisplayInfo) -> some View {
        Menu {
            Button(T("跟随自动规则")) {
                service.setDisplayItem(nil, for: display.id)
            }
            Divider()
            ForEach(library.items) { item in
                Button(item.name) {
                    service.setDisplayItem(item.id, for: display.id)
                }
            }
            if !library.systemItems.isEmpty {
                Divider()
                ForEach(library.systemItems) { item in
                    Button(TF("Apple · %@", item.name)) {
                        service.setDisplayItem(item.id, for: display.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if service.isOverridden(display.id) {
                    Image(systemName: "photo")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(service.currentItem(for: display.id)?.name ?? T("未指定"))
                        .lineLimit(1)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(T("跟随自动规则"))
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func fillMenu(_ display: WallpaperService.DisplayInfo) -> some View {
        let override = service.config.perDisplayFill[display.id]
        return Menu {
            Button(TF("跟随全局（%@）", service.config.fill.title)) {
                service.setDisplayFill(nil, for: display.id)
            }
            Divider()
            ForEach(WallpaperFill.allCases) { fill in
                Button(fill.title) {
                    service.setDisplayFill(fill, for: display.id)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: (override ?? service.config.fill).symbol)
                    .font(.system(size: 9, weight: .medium))
                Text(override?.title ?? T("跟随全局"))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
