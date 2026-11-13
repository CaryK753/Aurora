import SwiftUI

/// 更新后首次启动的「新功能」窗口：沿用欢迎窗的结构（大图标 + 标题 + 可滚动内容 + 底部按钮）
struct WhatsNewView: View {
    var notes: ReleaseNotes?
    var version: String
    var onContinue: () -> Void
    var onOpenReleasePage: () -> Void

    /// 每组最多铺几条：说明太长时剩下的收进「查看完整更新日志」
    private let itemLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id(topID)
                        header
                        if let notes, !notes.isEmpty {
                            content(notes)
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 56)
                    .padding(.top, 30)
                    .padding(.bottom, 26)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.top)
                .overlay(alignment: .bottom) {
                    // 底部压一层渐隐，提示下面还有内容（不然文字会被窗口边缘直接切一半）
                    LinearGradient(
                        colors: [Color(nsColor: .windowBackgroundColor).opacity(0), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 26)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    // 键盘焦点偶尔会先落到内容里的可点项上，把滚动位置带到底部
                    proxy.scrollTo(topID, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(topID, anchor: .top)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { onContinue() }
    }

    private let topID = "whatsnew-top"

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(version.isEmpty ? T("新功能") : TF("Aurora %@ 的新功能", version))
                    .font(.system(size: 27, weight: .bold))
                if let headline = notes?.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.bottom, 26)
    }

    // MARK: - 正文

    private func content(_ notes: ReleaseNotes) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(notes.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 { divider }
                sectionView(section)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func sectionView(_ section: ReleaseNotes.Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !section.title.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: symbol(for: section.title))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(sectionTitle(section.title))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                }
            }
            ForEach(section.items.prefix(itemLimit)) { item in
                itemView(item)
            }
            let rest = section.items.count - itemLimit
            if rest > 0 {
                HStack(spacing: 4) {
                    Text(TF("…以及另外 %d 项", rest))
                        .font(.system(size: 12))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 16)
                .contentShape(Rectangle())
                .onTapGesture { onOpenReleasePage() }
                .accessibilityAddTraits(.isButton)
                .help(T("查看完整更新日志"))
            }
        }
    }

    private func itemView(_ item: ReleaseNotes.Item) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 5, height: 5)
                .padding(.top, 6.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.detail.isEmpty {
                    Text(attributed(item.detailRuns))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(T("这个版本没有单独的更新说明"))
                .font(.callout).foregroundStyle(.secondary)
            Text(T("可以到 GitHub 上查看完整的更新日志。"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 44)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.6)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                onOpenReleasePage()
            } label: {
                HStack(spacing: 4) {
                    Text(T("查看完整更新日志"))
                        .font(.system(size: 11.5))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("在浏览器中打开 Release 页面"))

            Spacer(minLength: 8)

            Button(T("继续")) { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    // MARK: - 工具

    private func attributed(_ runs: [NoteRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.strong { piece.font = .system(size: 12.5, weight: .semibold) }
            result += piece
        }
        return result
    }

    /// 段落标题（新增 / 修复 …）在英文界面下翻一下；其余原样显示
    private func sectionTitle(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard L10n.effective == "en" else { return key }
        let known = [
            "新增": "New", "新功能": "New", "修复": "Fixes", "修复问题": "Fixes",
            "改进": "Improvements", "优化": "Improvements", "变更": "Changes",
            "移除": "Removed", "其他": "Other", "已知问题": "Known issues",
        ]
        return known[key] ?? key
    }

    private func symbol(for title: String) -> String {
        if title.contains("修复") { return "wrench.and.screwdriver.fill" }
        if title.contains("新增") || title.contains("新功能") { return "sparkles" }
        if title.contains("改进") || title.contains("优化") { return "arrow.up.circle.fill" }
        if title.contains("移除") { return "trash" }
        return "circle.grid.2x2.fill"
    }
}
