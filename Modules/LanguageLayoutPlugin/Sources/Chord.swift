//  Chord.swift
//  LanguageLayoutPlugin — 在英文键盘上怎么打出某个字符
//
//  优先用运行时从系统 ABC 布局算出来的表（真实、随系统变化）；
//  读不到时退回这里的内置表。数据都在本机用 UCKeyTranslate 核对过。

import Foundation

/// 一个字符的打法。`steps` 是依次要按的键，最后一步才是真正的字母。
public struct Chord: Equatable, Hashable, Sendable {
    public var steps: [String]
    /// 需要先按死键（⌥U 之类）再按字母。
    public var isDeadKey: Bool

    public init(_ steps: [String], deadKey: Bool = false) {
        self.steps = steps
        self.isDeadKey = deadKey
    }

    public var display: String { steps.joined(separator: " → ") }

    /// 只有一个组合键，例如 ß = ⌥S。
    public var isSingleStroke: Bool { steps.count == 1 }
}

public struct ChordBook: Equatable, Sendable {
    public private(set) var chords: [String: Chord]

    public init(_ chords: [String: Chord] = [:]) {
        self.chords = chords
    }

    public static let empty = ChordBook()

    public var isEmpty: Bool { chords.isEmpty }

    public func chord(for character: Character) -> Chord? {
        chords[String(character)]
    }

    public func chord(for text: String) -> Chord? {
        chords[text]
    }

    /// 单词里所有需要组合键的字符，按出现顺序、去重。
    public func specialCharacters(in word: String) -> [Character] {
        var seen = Set<Character>()
        var result: [Character] = []
        for character in word where chord(for: character) != nil {
            if seen.insert(character).inserted { result.append(character) }
        }
        return result
    }

    /// 练习时提示「下一个字符怎么打」。已经能直接打出来的字符返回 nil。
    public func hint(for character: Character) -> String? {
        guard let chord = chord(for: character) else { return nil }
        return chord.display
    }

    public var all: [Chord] {
        chords.values.sorted { $0.steps.joined() < $1.steps.joined() }
    }
}

// MARK: - 内置兜底表

public extension ChordBook {
    /// 在 macOS 的「ABC」布局上验证过的组合键。
    static func builtIn(for language: TypingLanguage) -> ChordBook {
        switch language.id {
        case "de": return german
        case "fr": return french
        case "es": return spanish
        default: return ChordBook()
        }
    }

    static let german = ChordBook([
        "ä": Chord(["⌥U", "A"], deadKey: true),
        "ö": Chord(["⌥U", "O"], deadKey: true),
        "ü": Chord(["⌥U", "U"], deadKey: true),
        "Ä": Chord(["⌥U", "⇧A"], deadKey: true),
        "Ö": Chord(["⌥U", "⇧O"], deadKey: true),
        "Ü": Chord(["⌥U", "⇧U"], deadKey: true),
        "ß": Chord(["⌥S"]),
        "ẞ": Chord(["⌥⇧S"]),
        "€": Chord(["⌥⇧2"]),
        "„": Chord(["⌥⇧W"]),
        "“": Chord(["⌥["]),
        "”": Chord(["⌥⇧["]),
    ])

    static let french = ChordBook([
        "é": Chord(["⌥E", "E"], deadKey: true),
        "è": Chord(["⌥`", "E"], deadKey: true),
        "ê": Chord(["⌥I", "E"], deadKey: true),
        "ë": Chord(["⌥U", "E"], deadKey: true),
        "à": Chord(["⌥`", "A"], deadKey: true),
        "â": Chord(["⌥I", "A"], deadKey: true),
        "ç": Chord(["⌥C"]),
        "Ç": Chord(["⌥⇧C"]),
        "ù": Chord(["⌥`", "U"], deadKey: true),
        "û": Chord(["⌥I", "U"], deadKey: true),
        "î": Chord(["⌥I", "I"], deadKey: true),
        "ï": Chord(["⌥U", "I"], deadKey: true),
        "ô": Chord(["⌥I", "O"], deadKey: true),
        "œ": Chord(["⌥Q"]),
        "Œ": Chord(["⌥⇧Q"]),
        "É": Chord(["⌥E", "⇧E"], deadKey: true),
        "«": Chord(["⌥\\"]),
        "»": Chord(["⌥⇧\\"]),
        "€": Chord(["⌥⇧2"]),
    ])

    static let spanish = ChordBook([
        "ñ": Chord(["⌥N", "N"], deadKey: true),
        "Ñ": Chord(["⌥N", "⇧N"], deadKey: true),
        "á": Chord(["⌥E", "A"], deadKey: true),
        "é": Chord(["⌥E", "E"], deadKey: true),
        "í": Chord(["⌥E", "I"], deadKey: true),
        "ó": Chord(["⌥E", "O"], deadKey: true),
        "ú": Chord(["⌥E", "U"], deadKey: true),
        "ü": Chord(["⌥U", "U"], deadKey: true),
        "Á": Chord(["⌥E", "⇧A"], deadKey: true),
        "É": Chord(["⌥E", "⇧E"], deadKey: true),
        "Í": Chord(["⌥E", "⇧I"], deadKey: true),
        "Ó": Chord(["⌥E", "⇧O"], deadKey: true),
        "Ú": Chord(["⌥E", "⇧U"], deadKey: true),
        "Ü": Chord(["⌥U", "⇧U"], deadKey: true),
        "¿": Chord(["⌥⇧?"]),
        "¡": Chord(["⌥1"]),
        "€": Chord(["⌥⇧2"]),
    ])
}
