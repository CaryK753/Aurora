//  LanguageCatalog.swift
//  LanguageLayoutPlugin — 小语种键盘布局教练的语言数据
//
//  这里只放「学这门语言要打什么」：字符集、键位家族、练习词与提示。
//  键位长什么样不写死——运行时从系统布局读，Apple 改布局也不会失真。

import Foundation

/// 一个练习词：目标文字 + 中英文释义，给练习时当提示。
public struct DrillWord: Identifiable, Equatable, Sendable {
    public var id: String { text }
    public var text: String
    public var hint: String
    public var hintEN: String

    public init(_ text: String, _ hint: String, _ hintEN: String) {
        self.text = text
        self.hint = hint
        self.hintEN = hintEN
    }
}

public struct TypingLanguage: Identifiable, Equatable, Sendable {
    public enum LayoutFamily: String, Sendable, Equatable {
        case qwertz, azerty, qwerty

        public var title: String {
            switch self {
            case .qwertz: return "QWERTZ"
            case .azerty: return "AZERTY"
            case .qwerty: return "QWERTY"
            }
        }
    }

    public let id: String
    /// 系统输入源 ID（`com.apple.keylayout.German` 这类），用来读真实键位。
    public let layoutID: String
    /// 这门语言自己的写法
    public let nativeName: String
    public let chineseName: String
    public let englishName: String
    public let family: LayoutFamily
    /// 值得专门练的字符（含大小写里更常用的那个）。
    public let specialCharacters: [String]
    /// 与中文/英文键盘最不一样的地方，给用户一句人话。
    public let notes: [String]
    public let notesEN: [String]
    public let words: [DrillWord]

    public var displayName: String { nativeName }
}

// MARK: - 内置语言

public extension TypingLanguage {
    static let german = TypingLanguage(
        id: "de",
        layoutID: "com.apple.keylayout.German",
        nativeName: "Deutsch",
        chineseName: "德语",
        englishName: "German",
        family: .qwertz,
        specialCharacters: ["ä", "ö", "ü", "ß", "Ä", "Ö", "Ü", "€"],
        notes: [
            "Y 和 Z 互换：打字时 z 在左手边，y 在右手上排。",
            "ä ö ü 在右手区：ä 是分号键、ö 是 L 右边、ü 是 P 右边。",
            "ß 在数字 0 的右边，不用组合键。",
        ],
        notesEN: [
            "Y and Z are swapped: z sits under the left hand, y on the top row of the right.",
            "ä, ö and ü live on the right: ä on the semicolon key, ö right of L, ü right of P.",
            "ß sits right of the 0 key with no modifier.",
        ],
        words: [
            DrillWord("Größe", "大小", "size"),
            DrillWord("Übung", "练习", "practice"),
            DrillWord("schön", "漂亮的", "beautiful"),
            DrillWord("Mädchen", "女孩", "girl"),
            DrillWord("Straße", "街道", "street"),
            DrillWord("Brötchen", "小面包", "bread roll"),
            DrillWord("können", "能够", "can"),
            DrillWord("fünf", "五", "five"),
            DrillWord("Zürich", "苏黎世", "Zurich"),
            DrillWord("Käse", "奶酪", "cheese"),
            DrillWord("müde", "累的", "tired"),
            DrillWord("Löffel", "勺子", "spoon"),
            DrillWord("Häuser", "房子（复数）", "houses"),
            DrillWord("Grüße", "问候", "greetings"),
        ]
    )

    static let french = TypingLanguage(
        id: "fr",
        layoutID: "com.apple.keylayout.French",
        nativeName: "Français",
        chineseName: "法语",
        englishName: "French",
        family: .azerty,
        specialCharacters: ["é", "è", "ê", "à", "ç", "ù", "œ", "É", "Ç", "«", "»"],
        notes: [
            "AZERTY：A 和 Q、Z 和 W 互换，M 跑到右手分号键。",
            "数字要按 Shift，不按 Shift 得到的是 é è ç à 这些常用字母。",
            "ç 在数字 9 的位置，œ 用 ⌥Q。",
        ],
        notesEN: [
            "AZERTY: A and Q swap, so do Z and W, and M moves to the semicolon key.",
            "Digits need Shift; unshifted that row gives é, è, ç, à and friends.",
            "ç sits on the 9 key; œ is ⌥Q.",
        ],
        words: [
            DrillWord("français", "法语", "French"),
            DrillWord("être", "是", "to be"),
            DrillWord("école", "学校", "school"),
            DrillWord("ça", "这个", "that"),
            DrillWord("déjà", "已经", "already"),
            DrillWord("hôtel", "旅馆", "hotel"),
            DrillWord("garçon", "男孩", "boy"),
            DrillWord("crème", "奶油", "cream"),
            DrillWord("très", "非常", "very"),
            DrillWord("élève", "学生", "pupil"),
            DrillWord("cœur", "心", "heart"),
            DrillWord("Noël", "圣诞节", "Christmas"),
            DrillWord("château", "城堡", "castle"),
            DrillWord("où", "哪里", "where"),
        ]
    )

    static let spanish = TypingLanguage(
        id: "es",
        layoutID: "com.apple.keylayout.Spanish",
        nativeName: "Español",
        chineseName: "西班牙语",
        englishName: "Spanish",
        family: .qwerty,
        specialCharacters: ["ñ", "á", "é", "í", "ó", "ú", "ü", "¿", "¡", "Ñ"],
        notes: [
            "字母行和英文键盘一样，只有 ñ 落在分号键。",
            "标点被重排：¿ 在逗号键、¡ 在 1 键，感叹号和问号要配对使用。",
            "重音符号用死键：⌥E 再按字母是 é，⌥N 再按 n 是 ñ。",
        ],
        notesEN: [
            "The letter rows match a US keyboard; only ñ moves onto the semicolon key.",
            "Punctuation moves: ¿ on the comma key, ¡ on the 1 key, and both open a sentence.",
            "Accents come from dead keys: ⌥E then a letter gives é, ⌥N then n gives ñ.",
        ],
        words: [
            DrillWord("mañana", "明天", "tomorrow"),
            DrillWord("español", "西班牙语", "Spanish"),
            DrillWord("niño", "孩子", "child"),
            DrillWord("años", "年（复数）", "years"),
            DrillWord("qué", "什么", "what"),
            DrillWord("cómo", "怎样", "how"),
            DrillWord("también", "也", "also"),
            DrillWord("señor", "先生", "sir"),
            DrillWord("día", "白天", "day"),
            DrillWord("música", "音乐", "music"),
            DrillWord("corazón", "心", "heart"),
            DrillWord("pingüino", "企鹅", "penguin"),
            DrillWord("¿qué tal?", "你好吗", "how are you"),
            DrillWord("¡hola!", "你好", "hello"),
        ]
    )

    /// 现在支持的语言。顺序就是界面上的顺序。
    static let catalog: [TypingLanguage] = [.german, .french, .spanish]

    static func language(id: String) -> TypingLanguage? {
        catalog.first { $0.id == id }
    }
}
