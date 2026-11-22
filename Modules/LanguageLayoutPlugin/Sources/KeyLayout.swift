//  KeyLayout.swift
//  LanguageLayoutPlugin — 物理键位、布局快照与差异比较
//
//  「目标语言布局」与「我现在用的 ABC」各是一张 keyCode → 字符的表；
//  两边一减就知道哪些键换了位置、哪些字符是新长出来的。

import Foundation

/// 一个物理键在某个布局下打出来的字符（不按 / 按住 Shift）。
public struct KeyOutput: Equatable, Sendable {
    public var base: String
    public var shift: String

    public init(base: String, shift: String) {
        self.base = base
        self.shift = shift
    }

    public var isEmpty: Bool { base.isEmpty && shift.isEmpty }
}

/// 一次读取到的布局：哪些键打什么，以及这张布局上所有字符该怎么打。
public struct LayoutSnapshot: Equatable, Sendable {
    public var layoutID: String
    public var languageID: String
    public var keys: [UInt16: KeyOutput]
    public var chords: ChordBook
    /// 读不到系统布局时为 true，此时 keys 可能只有兜底数据。
    public var isFallback: Bool

    public init(layoutID: String, languageID: String, keys: [UInt16: KeyOutput],
                chords: ChordBook, isFallback: Bool = false) {
        self.layoutID = layoutID
        self.languageID = languageID
        self.keys = keys
        self.chords = chords
        self.isFallback = isFallback
    }

    public func output(_ code: UInt16) -> KeyOutput? { keys[code] }
}

// MARK: - 键盘外观

/// 画键盘用的物理键位定义（ANSI）。宽度单位以 1 个字母键为基准。
public struct PhysicalKey: Identifiable, Equatable, Sendable {
    public var code: UInt16
    /// 键帽上的英文名（US 布局的样子），画空键与提示用。
    public var name: String
    public var units: Double

    public var id: UInt16 { code }

    public init(_ code: UInt16, _ name: String, units: Double = 1) {
        self.code = code
        self.name = name
        self.units = units
    }
}

public struct PhysicalRow: Identifiable, Equatable, Sendable {
    public var id: Int
    public var keys: [PhysicalKey]
    /// 行首缩进（键位宽度单位），做出错位排布。
    public var leading: Double

    public init(id: Int, leading: Double, keys: [PhysicalKey]) {
        self.id = id
        self.leading = leading
        self.keys = keys
    }
}

public enum PhysicalKeyboard {
    /// 只画字母与数字区：这是小语种最容易出错的部分，也足够在小面板里看清。
    public static let rows: [PhysicalRow] = [
        PhysicalRow(id: 0, leading: 0, keys: [
            PhysicalKey(50, "`"), PhysicalKey(18, "1"), PhysicalKey(19, "2"), PhysicalKey(20, "3"),
            PhysicalKey(21, "4"), PhysicalKey(23, "5"), PhysicalKey(22, "6"), PhysicalKey(26, "7"),
            PhysicalKey(28, "8"), PhysicalKey(25, "9"), PhysicalKey(29, "0"), PhysicalKey(27, "-"),
            PhysicalKey(24, "="),
        ]),
        PhysicalRow(id: 1, leading: 0.35, keys: [
            PhysicalKey(12, "Q"), PhysicalKey(13, "W"), PhysicalKey(14, "E"), PhysicalKey(15, "R"),
            PhysicalKey(17, "T"), PhysicalKey(16, "Y"), PhysicalKey(32, "U"), PhysicalKey(34, "I"),
            PhysicalKey(31, "O"), PhysicalKey(35, "P"), PhysicalKey(33, "["), PhysicalKey(30, "]"),
            PhysicalKey(42, "\\"),
        ]),
        PhysicalRow(id: 2, leading: 0.7, keys: [
            PhysicalKey(0, "A"), PhysicalKey(1, "S"), PhysicalKey(2, "D"), PhysicalKey(3, "F"),
            PhysicalKey(5, "G"), PhysicalKey(4, "H"), PhysicalKey(38, "J"), PhysicalKey(40, "K"),
            PhysicalKey(37, "L"), PhysicalKey(41, ";"), PhysicalKey(39, "'"),
        ]),
        PhysicalRow(id: 3, leading: 1.05, keys: [
            PhysicalKey(6, "Z"), PhysicalKey(7, "X"), PhysicalKey(8, "C"), PhysicalKey(9, "V"),
            PhysicalKey(11, "B"), PhysicalKey(45, "N"), PhysicalKey(46, "M"), PhysicalKey(43, ","),
            PhysicalKey(47, "."), PhysicalKey(44, "/"),
        ]),
    ]

    /// 英文键盘的参照字符，用来判断「这个键还是不是原来那个」。
    public static let reference: [UInt16: KeyOutput] = {
        var map: [UInt16: KeyOutput] = [:]
        for row in rows {
            for key in row.keys {
                let base = key.name.lowercased()
                let shift = key.name
                map[key.code] = KeyOutput(base: base, shift: shift)
            }
        }
        // 数字行与符号键的 Shift 结果
        let shifted: [UInt16: (String, String)] = [
            50: ("`", "~"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"),
            23: ("5", "%"), 22: ("6", "^"), 26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("),
            29: ("0", ")"), 27: ("-", "_"), 24: ("=", "+"), 33: ("[", "{"), 30: ("]", "}"),
            42: ("\\", "|"), 41: (";", ":"), 39: ("'", "\""), 43: (",", "<"), 47: (".", ">"),
            44: ("/", "?"),
        ]
        for (code, pair) in shifted { map[code] = KeyOutput(base: pair.0, shift: pair.1) }
        return map
    }()
}

// MARK: - 与英文键盘的差异

public struct KeyDelta: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 与英文键盘一致，不用管。
        case same
        /// 这个键换成了另一个字符。
        case replaced
        /// 两个键互相换了位置（德语 Y/Z、法语 A/Q）。
        case swapped
        /// 英文键盘上没有这个字符。
        case added
        /// 这个位置在目标布局里是空的。
        case missing
    }

    public var code: UInt16
    public var reference: KeyOutput?
    public var target: KeyOutput?
    public var kind: Kind
    /// 互换时的另一个键。
    public var partner: UInt16?

    public var id: UInt16 { code }
}

/// 一条「这个键不一样」的说明，交给界面决定怎么措辞。
public struct LayoutNote: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 两个字母互换，例如德语 Z ↔ Y。
        case swapped
        /// 这个键上多了一个本语言字符，例如 ñ 在分号键。
        case added
        /// 这个键被换成了别的符号。
        case replaced
    }

    public var id: String { "\(kind)-\(character)-\(other)" }
    public var kind: Kind
    public var character: String
    /// 互换时的另一个字母，或所在键的英文名。
    public var other: String

    public init(kind: Kind, character: String, other: String) {
        self.kind = kind
        self.character = character
        self.other = other
    }
}

public enum LayoutComparison {
    /// 逐键比较，只返回需要提醒的键（完全一致的键会被过滤掉）。
    public static func compare(target: [UInt16: KeyOutput],
                               reference: [UInt16: KeyOutput] = PhysicalKeyboard.reference) -> [KeyDelta] {
        var deltas: [KeyDelta] = []
        var swapped: Set<UInt16> = []

        for (code, output) in target.sorted(by: { $0.key < $1.key }) {
            guard let ref = reference[code] else {
                if !output.isEmpty {
                    deltas.append(KeyDelta(code: code, reference: nil, target: output, kind: .added))
                }
                continue
            }
            if output.isEmpty {
                deltas.append(KeyDelta(code: code, reference: ref, target: output, kind: .missing))
                continue
            }
            // 只挪了 Shift 上的符号（德语 2 上面的引号之类）不影响学键位，跳过。
            if output.base == ref.base { continue }

            let isNewCharacter = output.base.unicodeScalars.contains { !$0.isASCII }
            if !isNewCharacter,
               let source = reference.first(where: { $0.value.base == output.base && $0.key != code }),
               let back = target[source.key], back.base == ref.base {
                if !swapped.contains(code), !swapped.contains(source.key) {
                    swapped.insert(code)
                    swapped.insert(source.key)
                    deltas.append(KeyDelta(code: code, reference: ref, target: output,
                                           kind: .swapped, partner: source.key))
                }
                continue
            }
            deltas.append(KeyDelta(code: code, reference: ref, target: output,
                                   kind: isNewCharacter ? .added : .replaced))
        }
        return deltas
    }

    /// 只关心字母：`ß`、`ñ`、`é` 要提醒，`+`、`´`、`§` 这类标点换了位置不用管。
    private static func isNoteworthy(_ character: String) -> Bool {
        character.first?.isLetter ?? false
    }

    /// 给界面用的一句话说明。「Z ↔ Y」这种比「键位不同」有用得多。
    /// 顺序按「互换 → 字母换位 → 新增字符」排，重要的不会因为截断被挤掉。
    public static func notes(_ deltas: [KeyDelta]) -> [LayoutNote] {
        var swappedNotes: [LayoutNote] = []
        var movedNotes: [LayoutNote] = []
        var addedNotes: [LayoutNote] = []
        let keyNames = Dictionary(uniqueKeysWithValues: PhysicalKeyboard.rows.flatMap(\.keys).map { ($0.code, $0.name) })
        for delta in deltas {
            guard let target = delta.target, let ref = delta.reference else { continue }
            switch delta.kind {
            case .swapped:
                // 一对互换只报一次。
                guard let partner = delta.partner, delta.code < partner else { continue }
                swappedNotes.append(LayoutNote(kind: .swapped, character: ref.base.uppercased(),
                                               other: target.base.uppercased()))
            case .added:
                // 标点挪位置（德语 ] 上是 +）对学键位没有帮助，只留字母与语言字符。
                guard Self.isNoteworthy(target.base) else { continue }
                addedNotes.append(LayoutNote(kind: .added, character: target.base,
                                             other: keyNames[delta.code] ?? "?"))
            case .replaced:
                // 只报「字母跑到符号键上」这种（法语 M 在分号键）。
                guard let first = target.base.first, first.isLetter else { continue }
                movedNotes.append(LayoutNote(kind: .replaced, character: target.base,
                                             other: keyNames[delta.code] ?? "?"))
            case .missing, .same:
                continue
            }
        }
        return swappedNotes + movedNotes + addedNotes
    }
}
