//  MiniClipboard.swift
//  Aurora — mini 剪切板：全局热键唤起的紧凑历史面板（交互参考 Maccy）
//
//  搜索框在底部、列表在上、↑↓ 选择、⏎ 粘贴、Esc 关闭、⌘1-9 直贴前九条、
//  ⌘⌫ 删除选中。面板是非激活的 NSPanel：变成 key 接收键盘，但不抢走
//  前台 App 的激活状态，粘贴目标不受影响。

import AppKit
import SwiftUI

// MARK: - 面板控制器

@MainActor
final class MiniClipboardController {
    static let shared = MiniClipboardController()

    private var panel: AuroraMiniPanel?
    private var observers: [NSObjectProtocol] = []
    /// AppDelegate 启动时注入
    var clipboard: ClipboardService?

    /// 上一次弹出用的锚点与探测结果（调试 / 自检用）
    private(set) var lastAnchor: MiniClipboardPlacement.Anchor = .mouse
    private(set) var lastProbe = CaretProbe()

    var isVisible: Bool { panel?.isVisible ?? false }
    /// 调试 / 自检用
    var panelFrame: NSRect? { panel?.frame }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let clipboard else { return }
        if panel == nil { panel = makePanel(clipboard: clipboard) }
        guard let panel else { return }

        // 先把锚点读出来再 orderFront：面板一旦成为 key window，
        // 系统级的聚焦元素就变成我们自己了。
        let probe = clipboard.anchorAtCaret ? CaretLocator.probe() : CaretProbe()
        let placement = MiniClipboardPlacement.resolve(
            size: Self.contentSize,
            probe: probe,
            mouse: NSEvent.mouseLocation
        )
        lastProbe = probe
        lastAnchor = placement.anchor
        Debug.log("mini clipboard anchor=\(placement.anchor.rawValue) role=\(probe.role) caret=\(String(describing: probe.caret)) field=\(String(describing: probe.field)) note=\(probe.note)")
        panel.setFrame(placement.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel(clipboard: ClipboardService) -> AuroraMiniPanel {
        let panel = AuroraMiniPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(
            rootView: MiniClipboardView(
                clipboard: clipboard,
                onClose: { [weak self] in self?.hide() }
            )
        )
        hosting.frame = NSRect(origin: .zero, size: Self.contentSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // 点击别处 / 面板失焦就收起
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.hide()
        })
        return panel
    }

    static let contentSize = CGSize(width: 320, height: 356)
}

/// 需要「能变 key 的 borderless 面板」来接住键盘输入
final class AuroraMiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SwiftUI 界面

struct MiniClipboardView: View {
    @ObservedObject var clipboard: ClipboardService
    var onClose: () -> Void

    @State private var selection = 0
    @State private var visible: [ClipItem] = []
    @State private var hovered: UUID?
    @FocusState private var searchFocused: Bool

    private let corner: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            list
            searchBar
        }
        .frame(width: MiniClipboardController.contentSize.width,
               height: MiniClipboardController.contentSize.height)
        // 液态玻璃：整块面板是一枚玻璃，内容浮在上面
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .onAppear {
            selection = 0
            searchFocused = true
            rebuild()
        }
        .onChange(of: clipboard.query) { _, _ in
            selection = 0
            rebuild()
        }
        .onChange(of: clipboard.items) { _, _ in
            rebuild()
        }
    }

    // MARK: 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if visible.isEmpty {
                        emptyView
                            .padding(.top, 48)
                    } else {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            MiniClipRow(
                                item: item,
                                thumbnail: item.kind == .image ? clipboard.thumbnail(for: item) : nil,
                                selected: index == selection,
                                hovered: hovered == item.id
                            )
                            .id(item.id)
                            .onTapGesture { commit(item) }
                            .onHover { inside in
                                if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .onChange(of: selection) { _, newValue in
                if let item = visible[safe: newValue] {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 7) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.quaternary)
            Text(clipboard.isEnabled ? T("还没有剪贴板记录") : T("剪贴板记录功能未开启"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(T("搜索剪贴板"), text: $clipboard.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($searchFocused)
                .onSubmit { commitSelected() }
                .onExitCommand { onClose() }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard !visible.isEmpty else { return .ignored }
                    let delta = press.key == .upArrow ? -1 : 1
                    selection = (selection + delta + visible.count) % visible.count
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    // ⌘1-9 直贴前九条
                    guard press.modifiers.contains(.command),
                          let digit = press.characters.first?.wholeNumberValue,
                          (1...9).contains(digit),
                          let item = visible[safe: digit - 1] else { return .ignored }
                    commit(item)
                    return .handled
                }

            if !clipboard.query.isEmpty {
                Button {
                    clipboard.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Text(visible.isEmpty ? "" : TF("%d 项", visible.count))
                .font(.system(size: 8, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background {
            // 搜索栏压一条更亮的分隔带，玻璃上仍能看出「这是输入区」
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.6)
                }
        }
    }

    // MARK: 逻辑

    private func rebuild() {
        let query = clipboard.query.trimmingCharacters(in: .whitespaces)
        let base = clipboard.items
        visible = query.isEmpty ? Array(base.prefix(30)) : Array(base.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }.prefix(30))
        if selection >= visible.count { selection = max(0, visible.count - 1) }
    }

    private func commitSelected() {
        guard let item = visible[safe: selection] else { return }
        commit(item)
    }

    private func commit(_ item: ClipItem) {
        onClose()
        clipboard.paste(item)
    }
}

// MARK: - 单行

struct MiniClipRow: View {
    let item: ClipItem
    let thumbnail: NSImage?
    let selected: Bool
    let hovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.16 : 0.07))
                )

            middle
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
            }
            sourceIcon
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AuroraTheme.accent.opacity(0.42))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                    }
            } else if hovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(2)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        case .rich:
            Image(systemName: "doc.richtext")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        case .link:
            Image(systemName: "link")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AuroraTheme.accent)
        case .file:
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        case .color:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(NSColor(hexString: item.colorHex ?? "#888888") ?? .gray))
                .frame(width: 16, height: 16)
                .padding(5)
        }
    }

    @ViewBuilder
    private var middle: some View {
        switch item.kind {
        case .image:
            Text(item.sizeLabel.map { T("图片 · " + $0) } ?? T("图片"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .color:
            Text(item.colorHex ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
        case .link:
            Text(item.text)
                .font(.system(size: 10.5))
                .foregroundStyle(AuroraTheme.accent)
                .lineLimit(1)
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text.split(separator: "\n").first.map(String.init) ?? item.text)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                if item.text.split(separator: "\n").count > 1 {
                    Text(TF("还有 %d 行", item.text.split(separator: "\n").count - 1))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if !item.sourceBundle.isEmpty {
            Image(nsImage: NSWorkspace.shared.icon(forFile:
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.sourceBundle)?.path ?? "/System/Library/CoreServices/Finder.app"))
                .resizable()
                .frame(width: 12, height: 12)
                .opacity(0.75)
        } else if !item.source.isEmpty {
            Text(item.source)
                .font(.system(size: 7.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
