//  DrillEngine.swift
//  LanguageLayoutPlugin — 打字练习与错键统计
//
//  引擎只管「打了什么、错了哪个字符、还剩几个词」，不碰界面、不碰键盘权限。
//  这样练习可以在普通文本框里完成，不需要拦截系统按键。

import Foundation

public struct CharacterStat: Codable, Equatable, Sendable {
    public var correct: Int
    public var wrong: Int

    public init(correct: Int = 0, wrong: Int = 0) {
        self.correct = correct
        self.wrong = wrong
    }

    public var attempts: Int { correct + wrong }
    public var accuracy: Double { attempts == 0 ? 1 : Double(correct) / Double(attempts) }
    public var isWeak: Bool { attempts >= 2 && accuracy < 0.8 }

    public mutating func record(_ ok: Bool) {
        if ok { correct += 1 } else { wrong += 1 }
    }
}

public struct DrillEngine: Equatable {
    public private(set) var language: TypingLanguage
    public private(set) var words: [DrillWord]
    public private(set) var index = 0
    public private(set) var typed = ""
    public private(set) var charStats: [String: CharacterStat] = [:]
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public private(set) var streak = 0
    public private(set) var bestStreak = 0
    public private(set) var completedWords = 0
    /// 本次练习一共按下的字符数（含错的）。
    public private(set) var keystrokes = 0
    public private(set) var mistakes = 0
    /// 最近一次打错的字符，界面上闪一下提示。
    public private(set) var lastMistake: String?

    public init(language: TypingLanguage, words: [DrillWord]? = nil, shuffled: Bool = false) {
        self.language = language
        var list = words ?? language.words
        if shuffled { list.shuffle() }
        self.words = list
    }

    public var current: DrillWord? {
        index < words.count ? words[index] : nil
    }

    public var isFinished: Bool { index >= words.count }

    public var progress: Double {
        words.isEmpty ? 0 : Double(completedWords) / Double(words.count)
    }

    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var accuracy: Double {
        keystrokes == 0 ? 1 : Double(keystrokes - mistakes) / Double(keystrokes)
    }

    /// 常用口径：5 个字符算一个词。
    public var wpm: Double {
        let minutes = elapsed / 60
        guard minutes > 0.01 else { return 0 }
        return Double(max(0, keystrokes - mistakes)) / 5 / minutes
    }

    /// 当前词是否打完了。
    public var isCurrentComplete: Bool {
        guard let current else { return false }
        return typed == current.text
    }

    // MARK: - 输入

    public mutating func start(at date: Date = Date()) {
        guard startedAt == nil else { return }
        startedAt = date
    }

    /// 文本框内容变化时调用。返回是否刚好完成当前词。
    @discardableResult
    public mutating func update(typed newValue: String, at date: Date = Date()) -> Bool {
        guard let current else { return false }
        start(at: date)
        let target = Array(current.text)

        // 超长输入截断到目标长度，避免把错误无限累积成噪音。
        var value = newValue
        if value.count > target.count { value = String(value.prefix(target.count)) }
        guard value != typed else { return false }

        let previous = Array(typed)
        let updated = Array(value)
        if updated.count > previous.count {
            // 接着往后打：新出现的字符逐个记分。
            for offset in previous.count..<updated.count {
                record(offset, typed: updated[offset], target: target)
            }
        } else if updated.count == previous.count,
                  let offset = updated.indices.last(where: { previous.indices.contains($0) && previous[$0] != updated[$0] }) {
            // 同一位置改字（退格后重打）：这一次按键也要算进去，否则纠正会被当成没发生。
            record(offset, typed: updated[offset], target: target)
        }
        typed = value
        if updated.count <= previous.count, updated != previous { lastMistake = nil }

        guard typed == current.text else { return false }
        completedWords += 1
        streak += 1
        bestStreak = max(bestStreak, streak)
        if completedWords >= words.count {
            finishedAt = date
        }
        return true
    }

    private mutating func record(_ offset: Int, typed character: Character, target: [Character]) {
        guard offset < target.count else { return }
        let expected = String(target[offset])
        let ok = String(character) == expected
        keystrokes += 1
        var stat = charStats[expected] ?? CharacterStat()
        stat.record(ok)
        charStats[expected] = stat
        if !ok {
            mistakes += 1
            lastMistake = String(character)
        }
    }

    /// 进入下一个词。没打完就调用会中断连击。
    public mutating func advance() {
        guard !isFinished else { return }
        if !isCurrentComplete { streak = 0 }
        index += 1
        typed = ""
        lastMistake = nil
        if index >= words.count { finishedAt = finishedAt ?? Date() }
    }

    public mutating func restart(words newWords: [DrillWord]? = nil, shuffled: Bool = false) {
        var list = newWords ?? language.words
        if shuffled { list.shuffle() }
        words = list
        index = 0
        typed = ""
        charStats = [:]
        startedAt = nil
        finishedAt = nil
        streak = 0
        bestStreak = 0
        completedWords = 0
        keystrokes = 0
        mistakes = 0
        lastMistake = nil
    }

    // MARK: - 结果

    /// 错得最多的字符，给「弱项」列表用。
    public func weakCharacters(limit: Int = 6) -> [(character: String, stat: CharacterStat)] {
        charStats
            .filter { $0.value.wrong > 0 }
            .sorted {
                if $0.value.wrong != $1.value.wrong { return $0.value.wrong > $1.value.wrong }
                return $0.value.accuracy < $1.value.accuracy
            }
            .prefix(limit)
            .map { (character: $0.key, stat: $0.value) }
    }
}

// MARK: - 跨会话进度

/// 每门语言一份，存 UserDefaults。
public struct LanguageProgress: Codable, Equatable, Sendable {
    public var stats: [String: CharacterStat]
    public var completedWords: Int
    public var bestWPM: Double
    public var sessions: Int
    public var lastPracticed: Date?

    public init(stats: [String: CharacterStat] = [:], completedWords: Int = 0,
                bestWPM: Double = 0, sessions: Int = 0, lastPracticed: Date? = nil) {
        self.stats = stats
        self.completedWords = completedWords
        self.bestWPM = bestWPM
        self.sessions = sessions
        self.lastPracticed = lastPracticed
    }

    public mutating func absorb(_ engine: DrillEngine, at date: Date = Date()) {
        for (character, stat) in engine.charStats {
            var merged = stats[character] ?? CharacterStat()
            merged.correct += stat.correct
            merged.wrong += stat.wrong
            stats[character] = merged
        }
        completedWords += engine.completedWords
        bestWPM = max(bestWPM, engine.wpm)
        sessions += 1
        lastPracticed = date
    }

    /// 只统计这门语言真正需要练的字符，避免把普通字母算进掌握度。
    public func mastery(for characters: [String]) -> Double {
        let relevant = characters.compactMap { stats[$0] }.filter { $0.attempts > 0 }
        guard !relevant.isEmpty else { return 0 }
        let correct = relevant.reduce(0) { $0 + $1.correct }
        let attempts = relevant.reduce(0) { $0 + $1.attempts }
        return attempts == 0 ? 0 : Double(correct) / Double(attempts)
    }

    public func weakCharacters(limit: Int = 6) -> [(character: String, stat: CharacterStat)] {
        stats
            .filter { $0.value.isWeak }
            .sorted { $0.value.accuracy < $1.value.accuracy }
            .prefix(limit)
            .map { (character: $0.key, stat: $0.value) }
    }
}
