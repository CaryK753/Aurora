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

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let clipboard else { return }
        if panel == nil { panel = makePanel(clipboard: clipboard) }
        guard let panel else { return }
        panel.setFrame(Self.frameForPanel(panel), display: true)
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
            contentRect: Self.frameForPanel(nil),
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

    static let contentSize = CGSize(width: 424, height: 496)

    /// 跟 Spotlight 一样：鼠标所在屏幕、水平居中、偏上
    private static func frameForPanel(_ panel: NSPanel?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel?.frame.size ?? contentSize
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.12
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }
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
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 列表
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        if visible.isEmpty {
                            emptyView
                                .padding(.top, 56)
                        } else {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                MiniClipRow(item: item, selected: index == selection)
                                    .id(item.id)
                                    .onTapGesture { commit(item) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, newValue in
                    if let item = visible[safe: newValue] {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 0)

            // 搜索框在底部（Maccy 的习惯）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField(T("搜索剪贴板"), text: $clipboard.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
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
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text(visible.isEmpty ? "" : TF("%d 项", visible.count))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quinary.opacity(0.5))
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.quaternary)
            Text(clipboard.isEnabled ? T("还没有剪贴板记录") : T("剪贴板记录功能未开启"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

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
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            middle
                .frame(maxWidth: .infinity, alignment: .leading)

            sourceIcon
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AuroraTheme.accent.opacity(0.16) : Color.clear)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
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
        case .image:
            if let url = URL(string: item.imageFile ?? ""), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(2)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .file:
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        case .color:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(NSColor(hexString: item.colorHex ?? "#888888") ?? .gray))
                .frame(width: 14, height: 14)
                .padding(4)
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
                .frame(width: 13, height: 13)
                .opacity(0.85)
        } else if !item.source.isEmpty {
            Text(item.source)
                .font(.system(size: 8))
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
