//  ClipboardView.swift
//  Aurora — 剪贴板历史

import AppKit
import SwiftUI

struct ClipboardView: View {
    @ObservedObject var service: ClipboardService
    @ObservedObject var state: AppState

    @State private var hoveredID: UUID?
    @State private var showSettings = false
    @State private var detail: ClipItem?
    @State private var editing: ClipItem?
    @State private var editText = ""
    @State private var patternInput = ""
    @State private var shortcutMonitor: Any?

    init(state: AppState) {
        self.state = state
        self.service = state.clipboard
    }

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                toolbar
                filterChips
                listCard
                if showSettings { settingsCard }
                footer
            }

            if let item = detail {
                detailOverlay(item)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(2)
            }

            if let item = editing {
                editOverlay(item)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(3)
            }
        }
        .animation(.smooth(duration: 0.2), value: detail?.id)
        .animation(.smooth(duration: 0.2), value: editing?.id)
        .onAppear { installShortcuts() }
        .onDisappear { removeShortcuts() }
    }

    // MARK: - 顶部

    private var toolbar: some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField(T("搜索"), text: $service.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !service.query.isEmpty {
                    Button { service.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7))

            Button {
                withAnimation(.smooth(duration: 0.22)) { showSettings.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(showSettings ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(showSettings ? 0.10 : 0.06)))
            }
            .buttonStyle(.plain)
            .help(T("记录规则"))

            Menu {
                Button(T("清空未固定")) {
                    service.clearUnpinned()
                    state.showToast(T("已清空未固定的记录"), symbol: "trash")
                }
                Button(T("清空全部"), role: .destructive) {
                    service.clearAll()
                    state.showToast(T("已清空剪贴板历史"), symbol: "trash")
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(T("清空"))

            AuroraToggle(isOn: Binding(
                get: { service.isEnabled },
                set: { service.setEnabled($0) }
            ))
            .help(T("启用"))
        }
    }

    private var filterChips: some View {
        HStack(spacing: 5) {
            ForEach(ClipFilter.allCases) { filter in
                    let active = service.filter == filter
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { service.filter = filter }
                    } label: {
                    HStack(spacing: 3) {
                        Text(T(filter.title))
                            .font(.system(size: 9, weight: active ? .semibold : .regular))
                        if filter == .pinned, service.pinnedCount > 0 {
                            Text("\(service.pinnedCount)")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }

    // MARK: - 列表

    private var listCard: some View {
        GlassCard(padding: 6) {
            VStack(spacing: 0) {
                if service.filtered.isEmpty {
                    EmptyHint(
                        symbol: "doc.on.clipboard",
                        text: service.query.isEmpty ? T("暂无剪贴板记录") : T("没有匹配的内容")
                    )
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(service.filtered.enumerated()), id: \.element.id) { index, item in
                                row(item)
                                if index < service.filtered.count - 1 {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.05))
                                        .frame(height: 0.6)
                                        .padding(.leading, 42)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: listHeight)
                }
            }
        }
    }

    /// 条目少时不要让卡片空出一大片，条目多时封顶 348pt 内部滚动
    private var listHeight: CGFloat {
        let count = service.filtered.count
        guard count > 0 else { return 118 }
        let full = min(348, CGFloat(min(count, 7)) * 54 + 6)
        // 展开记录规则时把列表收短，规则卡片能整块看到
        return showSettings ? min(full, 168) : full
    }

    private func row(_ item: ClipItem) -> some View {
        let hovered = hoveredID == item.id
        return HStack(spacing: 9) {
            leading(item)

            VStack(alignment: .leading, spacing: 2.5) {
                highlighted(item.preview)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    Text(T(item.kind.title))
                    Text("·")
                    Text(item.displaySource)
                        .lineLimit(1)
                    Text("·")
                    Text(Fmt.relative(item.date))
                    if item.copies > 1 {
                        Text("·")
                        Text(TF("%d 次", item.copies))
                    }
                }
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if let slot = service.shortcutIndex(for: item) {
                Text("⌘\(slot)")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
            } else if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(AuroraTheme.accent)
            }

            if hovered {
                HStack(spacing: 2) {
                    actionButton("eye") { detail = item }
                    actionButton(item.pinned ? "pin.slash" : "pin") { service.togglePin(item) }
                    actionButton("trash") { service.delete(item) }
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.05) : Color.clear)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
            }
        }
        .onTapGesture {
            if service.tapToPaste || NSEvent.modifierFlags.contains(.option) {
                service.paste(item)
                state.dismissMainPanel()
            } else {
                service.copy(item)
                state.showToast(T("已复制"), symbol: "doc.on.doc")
            }
        }
        .contextMenu {
            Button(T("复制")) { copy(item) }
            Button(T("粘贴")) {
                service.paste(item)
                state.dismissMainPanel()
            }
            if item.kind == .rich {
                Button(T("粘贴为纯文本")) { pastePlain(item) }
            }
            Divider()
            Button(T("查看详情")) { detail = item }
            if item.isTextual {
                Button(T("编辑")) { beginEdit(item) }
            }
            Button(item.pinned ? T("取消固定") : T("固定")) { service.togglePin(item) }
            if item.kind == .file || item.kind == .image {
                Button(T("在访达中显示")) { service.reveal(item) }
            }
            Divider()
            if !item.sourceBundle.isEmpty {
                Button(TF("不再记录 %@", item.displaySource)) {
                    service.ignoreApp(bundle: item.sourceBundle, name: item.displaySource)
                    state.showToast(TF("已忽略 %@", item.displaySource), symbol: "eye.slash")
                }
            }
            Button(T("删除"), role: .destructive) { service.delete(item) }
        }
    }

    @ViewBuilder
    private func leading(_ item: ClipItem) -> some View {
        if item.kind == .image, let image = service.thumbnail(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
                }
        } else if item.kind == .color, let hex = item.colorHex, let color = NSColor(hexString: hex) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(width: 30, height: 30)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.7)
                }
        } else if let icon = AppIconCache.icon(for: item.sourceBundle) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)
                .frame(width: 30, height: 30)
        } else {
            IconBadge(symbol: item.kind.symbol, size: 30, style: .tinted)
        }
    }

    private func highlighted(_ text: String) -> Text {
        let needle = service.query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Text(text) }
        var result = Text("")
        var rest = Substring(text)
        while let range = rest.range(of: needle, options: [.caseInsensitive]) {
            result = result + Text(String(rest[rest.startIndex..<range.lowerBound]))
            result = result + Text(String(rest[range]))
                .foregroundColor(AuroraTheme.accent)
                .bold()
            rest = rest[range.upperBound...]
        }
        return result + Text(String(rest))
    }

    private func actionButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 记录规则

    private var settingsCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: T("记录规则"), symbol: "slider.horizontal.3")
                    Spacer()
                    Text(service.isEnabled ? T("正在记录") : T("已暂停"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(service.isEnabled ? AuroraTheme.ok : Color.secondary)
                }

                HStack(spacing: 6) {
                    Text(T("保留"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    ForEach([20, 50, 100, 200], id: \.self) { value in
                        let active = service.limit == value
                        Button {
                            service.limit = value
                        } label: {
                            Text("\(value)")
                                .font(.system(size: 9, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3.5)
                                .background {
                                    Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    captureToggle(T("文本"), isOn: $service.captureText)
                    captureToggle(T("图片"), isOn: $service.captureImages)
                    captureToggle(T("文件"), isOn: $service.captureFiles)
                    Spacer(minLength: 0)
                }

                compactToggle(
                    symbol: "square.on.square",
                    title: T("合并重复内容"),
                    subtitle: T("再次复制同样的内容时只更新时间与次数"),
                    isOn: $service.dedupe
                )

                compactToggle(
                    symbol: "eye.slash",
                    title: T("忽略临时与机密内容"),
                    subtitle: T("密码管理器、瞬时标记的内容不写入历史"),
                    isOn: $service.ignoreConfidential
                )

                compactToggle(
                    symbol: "cursorarrow.rays",
                    title: T("单击直接粘贴"),
                    subtitle: T("点击记录就粘贴到上一个 App，不用再按 ⌘V"),
                    isOn: $service.tapToPaste
                )

                compactToggle(
                    symbol: "text.cursor",
                    title: T("贴在输入光标处"),
                    subtitle: T("mini 面板出现在正在输入的文本框旁；读不到光标时回到屏幕中上"),
                    isOn: $service.anchorAtCaret
                )

                compactToggle(
                    symbol: "arrow.down.forward.and.arrow.up.backward",
                    title: T("仅忽略下一次复制"),
                    subtitle: T("复制敏感内容前打开，复制后自动关闭"),
                    isOn: $service.ignoreNextCopy
                )

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                if !service.ignoredApps.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(T("已忽略的应用"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        FlowChips(items: service.ignoredApps) { bundle in
                            service.removeIgnoredApp(bundle)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(T("忽略匹配的内容"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        TextField(T("正则表达式，例如 ^sk-"), text: $patternInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.055)))
                            .onSubmit { addPattern() }
                        Button(T("添加")) { addPattern() }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(patternInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !service.ignoredPatterns.isEmpty {
                        FlowChips(items: service.ignoredPatterns) { pattern in
                            service.removeIgnorePattern(pattern)
                        }
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(TF("%d 条 · %@", service.items.count, storageLabel))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(T("清空未固定")) {
                        service.clearUnpinned()
                        state.showToast(T("已清空未固定的记录"), symbol: "trash")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    private var storageLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(max(service.byteTotal, 0)), countStyle: .file)
    }

    private func captureToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            AuroraToggle(isOn: isOn)
                .scaleEffect(0.82)
                .frame(width: 33, height: 19)
        }
    }

    private func compactToggle(symbol: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            AuroraToggle(isOn: isOn)
                .scaleEffect(0.86)
                .frame(width: 35, height: 20)
        }
    }

    private func addPattern() {
        let value = patternInput
        guard service.addIgnorePattern(value) else {
            state.showToast(T("正则表达式无效"), symbol: "exclamationmark.triangle")
            return
        }
        patternInput = ""
        state.showToast(T("已添加忽略规则"), symbol: "line.3.horizontal.decrease")
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: service.isPausedBySecureInput ? "lock.fill" : "lock.shield")
                .font(.system(size: 8.5))
                .foregroundStyle(service.isPausedBySecureInput ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(.tertiary))
            Text(service.isPausedBySecureInput ? T("检测到密码输入，已暂停记录") : T("⌘1–9 复制固定项 · ⌥ 单击直接粘贴"))
                .font(.system(size: 9))
                .foregroundStyle(service.isPausedBySecureInput ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
            Spacer()
            Text(TF("%d 个条目", service.items.count))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 详情 / 编辑

    private func detailOverlay(_ item: ClipItem) -> some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { detail = nil }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    IconBadge(symbol: item.kind.symbol, size: 24, style: .tinted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T(item.kind.title))
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(item.displaySource) · \(Fmt.relative(item.date))" + (item.sizeLabel.map { " · \($0)" } ?? ""))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { detail = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    detailContent(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 268)

                HStack(spacing: 6) {
                    Button(T("复制")) { copy(item) }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    if item.isTextual || item.kind == .color {
                        Button(T("纯文本")) { copyPlain(item) }
                            .buttonStyle(SoftButtonStyle())
                    }
                    Button(T("粘贴")) {
                        service.paste(item)
                        detail = nil
                        state.dismissMainPanel()
                    }
                        .buttonStyle(SoftButtonStyle())
                    Spacer()
                    if item.isTextual {
                        Button(T("编辑")) { beginEdit(item) }
                            .buttonStyle(SoftButtonStyle())
                    }
                    Button(T("删除")) {
                        service.delete(item)
                        detail = nil
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
            .padding(14)
            .frame(width: 400)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }

    @ViewBuilder
    private func detailContent(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            if let image = service.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        case .color:
            if let hex = item.colorHex, let color = NSColor(hexString: hex) {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(height: 150)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.8)
                        }
                    Text(hex)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Text(rgbText(color))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(item.text.split(separator: "\n"), id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(String(path))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        default:
            Text(item.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rgbText(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "R %d · G %d · B %d",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }

    private func editOverlay(_ item: ClipItem) -> some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { editing = nil }

            VStack(spacing: 10) {
                HStack {
                    Text(T("编辑内容"))
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text(TF("%d 字符", editText.count))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }

                TextEditor(text: $editText)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                    .frame(height: 230)

                HStack(spacing: 8) {
                    Spacer()
                    Button(T("取消")) { editing = nil }
                        .buttonStyle(SoftButtonStyle())
                    Button(T("保存")) {
                        service.updateText(editText, for: item)
                        editing = nil
                        state.showToast(T("已更新记录"), symbol: "checkmark.circle.fill")
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .frame(width: 400)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }

    // MARK: - 动作

    private func copy(_ item: ClipItem) {
        service.copy(item)
        state.showToast(T("已复制"), symbol: "doc.on.doc")
    }

    private func copyPlain(_ item: ClipItem) {
        service.copyPlainText(item)
        state.showToast(T("已复制为纯文本"), symbol: "textformat")
    }

    private func pastePlain(_ item: ClipItem) {
        service.paste(item, plainText: true)
        state.showToast(T("已粘贴为纯文本"), symbol: "textformat")
    }

    private func beginEdit(_ item: ClipItem) {
        detail = nil
        editText = item.text
        editing = item
    }

    // MARK: - 键盘快捷键

    private func installShortcuts() {
        removeShortcuts()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  let characters = event.charactersIgnoringModifiers,
                  let slot = Int(characters), (1...9).contains(slot),
                  let item = service.pinnedItem(at: slot - 1) else { return event }

            if event.modifierFlags.contains(.option) {
                service.paste(item)
                state.showToast(T("已粘贴"), symbol: "arrow.down.doc")
            } else {
                service.copy(item)
                state.showToast(TF("已复制 ⌘%d", slot), symbol: "doc.on.doc")
            }
            return nil
        }
    }

    private func removeShortcuts() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
    }
}

// MARK: - 辅助

@MainActor
private enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundle: String) -> NSImage? {
        guard !bundle.isEmpty else { return nil }
        if let cached = cache[bundle] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 26, height: 26)
        cache[bundle] = icon
        return icon
    }
}

private struct FlowChips: View {
    var items: [String]
    var onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(items, id: \.self) { value in
                    HStack(spacing: 3) {
                        Text(display(value))
                            .font(.system(size: 8.5))
                            .lineLimit(1)
                        Button { onRemove(value) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 6.5, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 22)
    }

    private func display(_ value: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) else { return value }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
