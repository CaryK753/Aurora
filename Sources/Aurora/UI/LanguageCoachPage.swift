//  LanguageCoachPage.swift
//  Aurora — 输入法 › 小语种键盘教练
//
//  三件事：看清目标语言的键位（与英文键盘差在哪）、查特殊字符怎么打、
//  用练习词把键位练熟。键位图来自系统布局，不是画出来的示意图。

import AppKit
import LanguageLayoutPlugin
import SwiftUI

struct LanguageCoachPage: View {
    @ObservedObject var state: AppState
    @ObservedObject private var service: LanguageTypingService

    init(state: AppState) {
        self.state = state
        self.service = state.languageTyping
    }

    var body: some View {
        VStack(spacing: 12) {
            languageCard
            KeyboardMapCard(service: service)
            ChordSheetCard(service: service, state: state)
            DrillCard(service: service)
            if !service.weakList.isEmpty {
                WeakCard(service: service)
            }
        }
        .onAppear { service.setVisible(true) }
        .onDisappear {
            service.setVisible(false)
            service.finishSession()
        }
    }

    private var languageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "globe.europe.africa.fill", size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.language.nativeName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(T("返回输入法")) {
                        withAnimation(.smooth(duration: 0.22)) { state.showLanguageCoach = false }
                    }
                    .buttonStyle(SoftButtonStyle())
                }

                HStack(spacing: 5) {
                    ForEach(service.languages) { language in
                        let active = language.id == service.selectedID
                        Button {
                            service.select(language.id)
                        } label: {
                            VStack(spacing: 1) {
                                Text(language.nativeName)
                                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                                Text(language.family.title)
                                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(active ? Color.white.opacity(0.8) : Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(active ? AnyShapeStyle(AuroraTheme.accentGradient)
                                                 : AnyShapeStyle(Color.primary.opacity(0.05)))
                            }
                            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(notes().enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .top, spacing: 5) {
                            Circle().fill(AuroraTheme.accent.opacity(0.5)).frame(width: 3.5, height: 3.5)
                                .padding(.top, 4.5)
                            Text(note)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let name = L10n.effective == "en" ? service.language.englishName : service.language.chineseName
        return name + " · " + service.language.family.title + " · " + TF("%d 个练习词", service.language.words.count)
    }

    private func notes() -> [String] {
        L10n.effective == "en" ? service.language.notesEN : service.language.notes
    }
}

// MARK: - 键位图

private struct KeyboardMapCard: View {
    @ObservedObject var service: LanguageTypingService
    @Environment(\.auroraContentWidth) private var contentWidth
    /// 卡片实际内宽。auroraContentWidth 在窗口首帧可能是默认值，直接用会把键盘撑出面板。
    @State private var measured: CGFloat = 0

    /// 13 个键位宽 + 行首缩进，按可用宽度反推单个键的尺寸。
    private var unit: CGFloat {
        let width = measured > 1 ? measured : max(280, contentWidth - 28)
        return min(34, max(19, (width - 3 * 12) / 14.2))
    }

    private var keyHeight: CGFloat { unit * 1.2 }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("键位图"), symbol: "keyboard")
                    if let snapshot = service.snapshot {
                        Text(snapshot.isFallback ? T("内置表") : service.language.layoutTitle)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if service.loading { ProgressView().controlSize(.mini) }
                    Text(T("小字是英文键盘上的原字符"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }

                keyboard
                footer
            }
        }
    }

    private var keyboard: some View {
        VStack(spacing: 3) {
            ForEach(PhysicalKeyboard.rows) { row in
                HStack(spacing: 3) {
                    if row.leading > 0 {
                        Color.clear.frame(width: row.leading * unit, height: keyHeight)
                    }
                    ForEach(row.keys) { key in
                        keycap(key)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { measured = geo.size.width }
                    .onChange(of: geo.size.width) { _, value in measured = value }
            }
        }
    }

    /// 先讲互换与换位，再讲多出来的字符；多出来的字符里优先这门语言要练的那些。
    private var orderedNotes: [LayoutNote] {
        let special = Set(service.language.specialCharacters)
        let swapped = service.notes.filter { $0.kind == .swapped }
        let moved = service.notes.filter { $0.kind == .replaced }
        let added = service.notes.filter { $0.kind == .added }
        return swapped + moved + added.filter { special.contains($0.character) }
            + added.filter { !special.contains($0.character) }
    }

    private var footer: some View {
        Group {
            if service.notes.isEmpty {
                Text(T("这门语言与英文键盘的字母位置一致，只需要记特殊字符。"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowNotes(notes: orderedNotes)
            }
        }
    }

    private func keycap(_ key: PhysicalKey) -> some View {
        let output = service.snapshot?.output(key.code)
        let reference = PhysicalKeyboard.reference[key.code]
        let base = output?.base ?? ""
        // 德语 ^、´ 这类死键：布局里有这个键但不直接出字符，用 ◌ 标出来。
        let deadKey = output != nil && base.isEmpty
        let changed = deadKey || (!base.isEmpty && base != reference?.base)
        let weak = !base.isEmpty && service.weakCharacters.contains(base)
        let tint = weak ? AuroraTheme.danger : (changed ? AuroraTheme.accent : Color.secondary)

        return VStack(spacing: 0) {
            HStack(spacing: 1) {
                Spacer(minLength: 0)
                if let shift = output?.shift, !shift.isEmpty, shift != base, changed {
                    Text(shift)
                        .font(.system(size: max(5.5, unit * 0.24), weight: .medium, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.55))
                }
            }
            if deadKey {
                Circle()
                    .strokeBorder(tint.opacity(0.8), lineWidth: 1)
                    .frame(width: unit * 0.34, height: unit * 0.34)
                    .frame(height: max(8, unit * 0.42))
            } else {
                Text(base.isEmpty ? key.name : base)
                    .font(.system(size: max(8, unit * 0.42), weight: changed ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(changed ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.85)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if changed, let old = reference?.base, !old.isEmpty {
                Text(old.uppercased())
                    .font(.system(size: max(5.5, unit * 0.22), design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
        .frame(width: unit, height: keyHeight)
        .background {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(changed ? AuroraTheme.accent.opacity(0.10) : Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .strokeBorder(weak ? AuroraTheme.danger.opacity(0.45) : Color.primary.opacity(0.05), lineWidth: 0.7)
        }
        .help(deadKey ? T("死键") + " · \(key.name)" : (base.isEmpty ? key.name : "\(base) · \(key.name)"))
    }
}

/// 键位变化的一句话说明，宽度不够时自动换行（不是横向滚动）。
private struct FlowNotes: View {
    var notes: [LayoutNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(notes.prefix(8)) { note in
                HStack(spacing: 5) {
                    Text(symbol(note.kind))
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(tint(note.kind))
                        .frame(width: 10)
                    Text(text(note))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func text(_ note: LayoutNote) -> String {
        switch note.kind {
        case .swapped: return TF("%@ ↔ %@ 互换位置", note.character, note.other)
        case .added: return TF("%@ 在 %@ 键", note.character, note.other)
        case .replaced: return TF("%@ 键上是 %@", note.other, note.character)
        }
    }

    private func symbol(_ kind: LayoutNote.Kind) -> String {
        switch kind {
        case .swapped: return "⇄"
        case .added: return "+"
        case .replaced: return "~"
        }
    }

    private func tint(_ kind: LayoutNote.Kind) -> Color {
        switch kind {
        case .swapped: return AuroraTheme.accent
        case .added: return AuroraTheme.ok
        case .replaced: return .secondary
        }
    }
}

// MARK: - 特殊字符速查

private struct ChordSheetCard: View {
    @ObservedObject var service: LanguageTypingService
    @ObservedObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 6)]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: T("特殊字符怎么打"), symbol: "character.cursor.ibeam")
                    Spacer()
                    Text(T("点一下复制字符"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(service.language.specialCharacters, id: \.self) { character in
                        chip(character)
                    }
                }
                Text(L10n.effective == "en"
                     ? "Chords are read from the ABC layout on this Mac. A dead key (⌥U) waits for the letter that follows."
                     : "组合键按本机 ABC 布局读出来：⌥U 这类死键按下后不会立刻出现字符，等下一个字母才合成。")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ character: String) -> some View {
        let chord = service.chordBook.chord(for: character)
        let weak = service.weakCharacters.contains(character)
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(character, forType: .string)
            state.showToast(TF("已复制 %@", character), symbol: "doc.on.clipboard")
        } label: {
            HStack(spacing: 6) {
                Text(character)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(weak ? AnyShapeStyle(AuroraTheme.danger) : AnyShapeStyle(Color.primary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    // 不用等宽：⇧ 在 9pt 等宽里会糊成一个小圈。
                    Text(chord?.display ?? "—")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(chord == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.accent))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let chord, chord.isDeadKey {
                        Text(T("死键"))
                            .font(.system(size: 7.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(weak ? AuroraTheme.danger.opacity(0.35) : Color.clear, lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 练习

private struct DrillCard: View {
    @ObservedObject var service: LanguageTypingService
    @FocusState private var focused: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                if service.engine.isFinished {
                    finished
                } else if service.engine.current != nil {
                    if service.engine.startedAt == nil {
                        startPrompt
                    } else {
                        activeDrill
                    }
                }
            }
        }
        .onChange(of: service.engine.index) { _, _ in focused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel(text: T("练习"), symbol: "keyboard.badge.ellipsis")
            Spacer(minLength: 4)
            if !service.engine.isFinished, service.engine.startedAt != nil {
                HStack(spacing: 5) {
                    Text(TF("%d / %d", service.engine.completedWords, service.engine.words.count))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(T("提示"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    AuroraToggle(isOn: $service.hintEnabled)
                }
                .fixedSize()
            }
        }
    }

    private var startPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("一轮 14 个词，只练这门语言里最容易打错的那些。打对自动进下一个。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(T("开始练习")) {
                    service.startDrill()
                    focused = true
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
                if service.currentProgress.completedWords > 0 {
                    Text(TF("累计练过 %d 个词", service.currentProgress.completedWords))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var activeDrill: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let word = service.engine.current {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    wordView(word)
                    Spacer(minLength: 4)
                    Text(L10n.effective == "en" ? word.hintEN : word.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TextField(T("在这里打出上面的词"), text: $service.typedText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(feedbackColor.opacity(0.45), lineWidth: 0.8)
                }
                .focused($focused)
                .onSubmit { service.submit() }

            HStack(spacing: 8) {
                hintChip
                if let mistake = service.lastMistake {
                    Text(TF("刚打错：%@", mistake))
                        .font(.system(size: 9))
                        .foregroundStyle(AuroraTheme.danger)
                }
                Spacer(minLength: 0)
                Button(T("跳过")) { service.skip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Button(T("重新开始")) { service.restartDrill() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            stats
        }
    }

    private var hintChip: some View {
        Group {
            if let hint = service.nextHint, let character = service.nextCharacter {
                HStack(spacing: 4) {
                    Text(character)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text(hint)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                .foregroundStyle(AuroraTheme.accent)
            } else if service.hintEnabled {
                Text(T("这个字符直接按就行"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            stat(T("正确率"), service.engine.keystrokes == 0 ? "—" : String(format: "%.0f%%", service.engine.accuracy * 100))
            stat(T("词/分"), String(format: "%.0f", service.engine.wpm))
            stat(T("连击"), "\(service.engine.streak)")
            Spacer()
            ProgressView(value: max(0.001, service.engine.progress))
                .progressViewStyle(.linear)
                .frame(width: 84)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AuroraTheme.ok)
                VStack(alignment: .leading, spacing: 1) {
                    Text(T("这一轮完成"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(TF("正确率 %.0f%% · 最好连击 %d", service.engine.accuracy * 100, service.engine.bestStreak))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button(T("再来一轮")) { service.restartDrill() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                if !service.weakList.isEmpty {
                    Text(TF("%d 个字符还需要多练", service.weakList.count))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var feedbackColor: Color {
        guard let mistake = service.lastMistake else {
            return service.engine.isCurrentComplete ? AuroraTheme.ok : Color.secondary.opacity(0.3)
        }
        return mistake.isEmpty ? Color.secondary.opacity(0.3) : AuroraTheme.danger
    }

    private func wordView(_ word: DrillWord) -> some View {
        let target = Array(word.text)
        let typed = Array(service.engine.typed)
        return HStack(spacing: 1) {
            ForEach(Array(target.enumerated()), id: \.offset) { index, character in
                let state: Int = index < typed.count
                    ? (typed[index] == character ? 1 : 2)
                    : (index == typed.count ? 3 : 0)
                Text(String(character))
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundStyle(color(state))
                    .padding(.horizontal, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(state == 3 ? AuroraTheme.accent.opacity(0.16) : Color.clear)
                    }
            }
        }
    }

    private func color(_ state: Int) -> Color {
        switch state {
        case 1: return AuroraTheme.ok
        case 2: return AuroraTheme.danger
        case 3: return .primary
        default: return Color.primary.opacity(0.45)
        }
    }
}

// MARK: - 弱项

private struct WeakCard: View {
    @ObservedObject var service: LanguageTypingService

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("我的弱项"), symbol: "exclamationmark.magnifyingglass")
                VStack(spacing: 3) {
                    ForEach(service.weakList, id: \.character) { item in
                        HStack(spacing: 8) {
                            Text(item.character)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .frame(width: 22)
                            Text(service.chordBook.chord(for: item.character)?.display ?? T("直接按"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(TF("%d 次里错 %d 次", item.stat.attempts, item.stat.wrong))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.0f%%", item.stat.accuracy * 100))
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(item.stat.accuracy < 0.6 ? AuroraTheme.danger : AuroraTheme.warn)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        }
                    }
                }
                Text(T("这些是练得最多的错处：先看清组合键，再重练一轮。"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
