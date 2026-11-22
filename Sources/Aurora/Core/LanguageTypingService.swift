//  LanguageTypingService.swift
//  Aurora — 小语种键盘教练
//
//  输入法模块下的插件：选一门语言，看它的键位与特殊字符，然后用练习词练手。
//  键位来自系统布局（KeyboardLayoutProbe），练习只在本应用窗口里读文本框，
//  不拦截系统按键，也不需要额外权限。

import AppKit
import Combine
import Foundation
import LanguageLayoutPlugin

@MainActor
final class LanguageTypingService: ObservableObject {
    @Published private(set) var languages = TypingLanguage.catalog
    @Published private(set) var selectedID: String
    @Published private(set) var snapshot: LayoutSnapshot?
    @Published private(set) var notes: [LayoutNote] = []
    @Published private(set) var progress: [String: LanguageProgress] = [:]
    @Published private(set) var engine: DrillEngine
    /// 练习时是否显示「下一个字符怎么打」。
    @Published var hintEnabled: Bool {
        didSet { ud.set(hintEnabled, forKey: Keys.hint) }
    }
    /// 正在等系统布局读取。
    @Published private(set) var loading = true
    @Published private(set) var lastMistake: String?

    /// 练习输入框绑定的文字。
    @Published var typedText = "" {
        didSet { handleTyping() }
    }

    var onToast: ((String, String) -> Void)?

    private let ud = UserDefaults.standard
    private enum Keys {
        static let language = "input.languageTyping.language"
        static let progress = "input.languageTyping.progress"
        static let hint = "input.languageTyping.hint"
    }

    private var moduleEnabled = true
    private var visible = false
    private var probeTask: Task<Void, Never>?
    /// 切语言时旧探测可能还在排队，用序号丢掉过期结果。
    private var probeGeneration = 0
    /// 这门语言的键位与说明（按 layoutID 存），再进页面时直接用，不再触发重排。
    private var snappedLayout: [String: (LayoutSnapshot, [LayoutNote])] = [:]
    private var advanceTask: Task<Void, Never>?
    private var syncingText = false
    private var absorbed = false

    init() {
        let saved = ud.string(forKey: Keys.language) ?? TypingLanguage.german.id
        let id = TypingLanguage.language(id: saved)?.id ?? TypingLanguage.german.id
        selectedID = id
        hintEnabled = ud.object(forKey: Keys.hint) as? Bool ?? true
        engine = DrillEngine(language: TypingLanguage.language(id: id) ?? .german)
        progress = Self.decode(ud.data(forKey: Keys.progress)) ?? [:]
        preloadLayout()
    }

    deinit {
        probeTask?.cancel()
        advanceTask?.cancel()
    }

    // MARK: - 状态

    var language: TypingLanguage {
        TypingLanguage.language(id: selectedID) ?? .german
    }

    var chordBook: ChordBook {
        if let snapshot, !snapshot.chords.isEmpty { return snapshot.chords }
        return .builtIn(for: language)
    }

    var currentProgress: LanguageProgress {
        progress[selectedID] ?? LanguageProgress()
    }

    var mastery: Double {
        currentProgress.mastery(for: language.specialCharacters)
    }

    /// 练习里刚打错的字符 + 历史弱项，键盘图上标红用。
    var weakCharacters: Set<String> {
        var set = Set(currentProgress.weakCharacters(limit: 8).map(\.character))
        for item in engine.weakCharacters(limit: 8) { set.insert(item.character) }
        return set
    }

    var weakList: [(character: String, stat: CharacterStat)] {
        currentProgress.weakCharacters(limit: 6)
    }

    /// 练习中的下一个字符该怎么打。已经能直接打出来的字符返回 nil。
    var nextHint: String? {
        guard hintEnabled, let word = engine.current else { return nil }
        let characters = Array(word.text)
        guard engine.typed.count < characters.count else { return nil }
        return chordBook.hint(for: characters[engine.typed.count])
    }

    var nextCharacter: String? {
        guard let word = engine.current else { return nil }
        let characters = Array(word.text)
        guard engine.typed.count < characters.count else { return nil }
        return String(characters[engine.typed.count])
    }

    // MARK: - 生命周期

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        if !enabled {
            probeTask?.cancel()
            probeTask = nil
            advanceTask?.cancel()
            advanceTask = nil
        }
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value { loadLayoutIfNeeded() }
    }

    func select(_ id: String) {
        guard id != selectedID, TypingLanguage.language(id: id) != nil else { return }
        finishSession()
        selectedID = id
        ud.set(id, forKey: Keys.language)
        engine = DrillEngine(language: language)
        syncingText = true
        typedText = ""
        syncingText = false
        lastMistake = nil
        absorbed = false
        loadLayoutIfNeeded()
    }

    /// 切语言时同步取：探针有缓存，命中时一次赋值就把页面画完，
    /// 不再「先画空壳、200 ms 后再重排一次」。
    private func loadLayoutIfNeeded() {
        probeTask?.cancel()
        let language = self.language
        if let cached = snappedLayout[language.layoutID] {
            apply(cached.0, cached.1)
            return
        }
        // 冷路径（这门语言第一次进来）：读一次系统布局，1–3 ms，仍在主线程（TIS 要求）。
        let snapshot = KeyboardLayoutProbe.snapshot(for: language)
        let noteList = LayoutComparison.notes(LayoutComparison.compare(target: snapshot.keys))
        if !snapshot.isFallback { snappedLayout[language.layoutID] = (snapshot, noteList) }
        apply(snapshot, noteList)
    }

    /// 启动时预热当前语言：探针第一次枚举输入源要几十毫秒，别留给页面首帧。
    private func preloadLayout() {
        probeTask?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        let language = self.language
        loading = snappedLayout[language.layoutID] == nil
        probeTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let snapshot = KeyboardLayoutProbe.snapshot(for: language)
            let noteList = LayoutComparison.notes(LayoutComparison.compare(target: snapshot.keys))
            guard !Task.isCancelled, let self, self.probeGeneration == generation else { return }
            if !snapshot.isFallback { self.snappedLayout[language.layoutID] = (snapshot, noteList) }
            // 页面没开着就不要发 @Published：启动时那一次发布会让整个面板重排一遍。
            guard self.visible, self.selectedID == language.id else {
                self.loading = false
                return
            }
            self.apply(snapshot, noteList)
        }
    }

    private func apply(_ snapshot: LayoutSnapshot, _ noteList: [LayoutNote]) {
        self.snapshot = snapshot
        self.notes = noteList
        self.loading = false
    }

    // MARK: - 练习

    func startDrill(shuffled: Bool = true) {
        finishSession()
        engine.restart(shuffled: shuffled)
        engine.start()
        syncingText = true
        typedText = ""
        syncingText = false
        lastMistake = nil
        absorbed = false
    }

    func restartDrill() {
        startDrill(shuffled: true)
    }

    func submit() {
        // 回车只在词打完之后才进下一个；打一半按回车不应该被当成跳过。
        guard !engine.isFinished, engine.isCurrentComplete else { return }
        advance()
    }

    func skip() {
        if !engine.isCurrentComplete { lastMistake = nil }
        advance()
    }

    private func handleTyping() {
        guard !syncingText else { return }
        guard !engine.isFinished else { return }
        guard moduleEnabled else { return }
        if engine.startedAt == nil { engine.start() }
        let completed = engine.update(typed: typedText)
        if engine.typed != typedText {
            syncingText = true
            typedText = engine.typed
            syncingText = false
        }
        lastMistake = engine.lastMistake
        guard completed else { return }
        // 打对了停一下让用户看见整词变绿，再进下一个。
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    private func advance() {
        advanceTask?.cancel()
        advanceTask = nil
        engine.advance()
        syncingText = true
        typedText = ""
        syncingText = false
        lastMistake = nil
        if engine.isFinished { finishSession() }
    }

    /// 一次练习结束后把错键统计并进长期进度。
    func finishSession() {
        guard !absorbed, engine.keystrokes > 0 else { return }
        absorbed = true
        var entry = progress[selectedID] ?? LanguageProgress()
        entry.absorb(engine)
        progress[selectedID] = entry
        if let data = try? JSONEncoder().encode(progress) { ud.set(data, forKey: Keys.progress) }
    }

    // MARK: - 持久化

    private nonisolated static func decode(_ data: Data?) -> [String: LanguageProgress]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: LanguageProgress].self, from: data)
    }
}
