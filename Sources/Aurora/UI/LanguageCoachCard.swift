//  LanguageCoachCard.swift
//  Aurora — 输入法 › 小语种键盘入口
//
//  输入法模块里的一张卡：选语言、看掌握度、进教练页。真正的键位图和练习
//  在 LanguageCoachPage（与全局快捷键页同层的单层内容页）。

import LanguageLayoutPlugin
import SwiftUI

struct LanguageCoachCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var service: LanguageTypingService

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                languageChips
                masteryRow
                if !service.weakList.isEmpty {
                    weakRow
                }
                Text(intro)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 语言名按当前目录拼出来，加语言时不用改文案。
    private var intro: String {
        let english = L10n.effective == "en"
        let names = service.languages.map { english ? $0.englishName : $0.chineseName }
        let joined: String
        if english {
            joined = names.count > 1
                ? names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
                : (names.first ?? "")
        } else {
            joined = names.joined(separator: "、")
        }
        return TF("用中文/英文键盘学%@：先看清特殊字符怎么打，再用练习词把键位练成肌肉记忆。", joined)
    }

    private var header: some View {
        HStack(spacing: 9) {
            IconBadge(symbol: "globe.europe.africa.fill", size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(T("小语种键盘"))
                    .font(.system(size: 11.5, weight: .medium))
                Text(T("特殊字符与键位互换，边看边练"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(T("打开")) {
                withAnimation(.smooth(duration: 0.22)) { state.showLanguageCoach = true }
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
        }
    }

    private var languageChips: some View {
        // 语言会越加越多，一行放不下就换行，不要挤成一团。
        ChipFlow(spacing: 5, rowSpacing: 5) {
            ForEach(service.languages) { language in
                chip(language)
            }
        }
    }

    private func chip(_ language: TypingLanguage) -> some View {
        let active = language.id == service.selectedID
        return Button {
            service.select(language.id)
        } label: {
            HStack(spacing: 4) {
                Text(language.nativeName)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Text(language.family.title)
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient)
                                      : AnyShapeStyle(Color.primary.opacity(0.06)))
            }
            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var masteryRow: some View {
        let progress = service.currentProgress
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0.02, service.mastery))
                    .stroke(AuroraTheme.accentGradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.0f", service.mastery * 100))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(T("特殊字符掌握度"))
                    .font(.system(size: 10))
                Text(progress.lastPracticed.map { TF("上次练习 %@", Fmt.relative($0)) }
                     ?? T("还没练过，先开始一轮练习"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if progress.bestWPM > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.0f", progress.bestWPM))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(T("最好词/分"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var weakRow: some View {
        HStack(spacing: 4) {
            Text(T("常错"))
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            ForEach(service.weakList.prefix(5), id: \.character) { item in
                Text(item.character)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(AuroraTheme.danger.opacity(0.12)))
                    .foregroundStyle(AuroraTheme.danger)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 一行放不下就换行的横向布局。语言胶囊用它，不横向滚动也不压缩文字。
private struct ChipFlow: Layout {
    var spacing: CGFloat = 5
    var rowSpacing: CGFloat = 5

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        let rows = arrange(subviews, width: limit)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, needed > width {
                rows.append(current)
                current = Row(items: [index], width: size.width, height: size.height)
            } else {
                current.items.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
