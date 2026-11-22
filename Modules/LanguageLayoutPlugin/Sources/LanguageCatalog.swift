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
    /// 系统设置里显示的输入源名。意大利语的 QWERTY 版 ID 是 Italian-Pro，
    /// 但系统里就叫「Italian」，别让用户照着 ID 去设置里找一个不存在的名字。
    public let layoutName: String
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

    /// 键位图角标用的布局名。
    public var layoutTitle: String {
        layoutName.isEmpty ? layoutID.replacingOccurrences(of: "com.apple.keylayout.", with: "") : layoutName
    }
}

// MARK: - 内置语言

public extension TypingLanguage {
    static let german = TypingLanguage(
        id: "de",
        layoutID: "com.apple.keylayout.German",
        layoutName: "German",
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
        layoutName: "French",
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
        layoutName: "Spanish",
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

    static let italian = TypingLanguage(
        id: "it",
        // 系统里叫「Italian」的那个就是 QWERTY，ID 却是 Italian-Pro；
        // 只有 ID 为 Italian 的是老打字机布局（QZERTY，Z/W 互换）。
        layoutID: "com.apple.keylayout.Italian-Pro",
        layoutName: "Italian",
        nativeName: "Italiano",
        chineseName: "意大利语",
        englishName: "Italian",
        family: .qwerty,
        specialCharacters: ["à", "è", "é", "ì", "ò", "ù", "À", "È", "É", "Ì", "Ò", "Ù", "€"],
        notes: [
            "字母行和英文键盘完全一样，A–Z 不用重新记。",
            "重音字母在右手边：[ 键是 è、; 键是 ò（加 Shift 是 ç）、' 键是 à、\\ 键是 ù，= 键是 ì。",
            "撇号挪到了 - 键（加 Shift 是 ?），真正的连字符在 / 键。",
            "macOS 里还有一个老式的「Italian – QZERTY」输入源（Z/W 互换、M 跑到 L 右边），那是打字机布局，日常别选它。",
        ],
        notesEN: [
            "The letter rows are identical to a US keyboard; nothing to relearn from A to Z.",
            "Accents sit on the right: è on [, ò on ; (ç with Shift), à on ', ù on \\ and ì on =.",
            "The apostrophe moved onto the - key (Shift gives ?), and the real hyphen is on /.",
            "macOS also ships a legacy \u{201C}Italian – QZERTY\u{201D} source (Z/W swapped, M beside L); that is the typewriter layout, don't pick it day to day.",
        ],
        words: [
            DrillWord("caffè", "咖啡", "coffee"),
            DrillWord("città", "城市", "city"),
            DrillWord("più", "更多", "more"),
            DrillWord("però", "但是", "but"),
            DrillWord("così", "这样", "like this"),
            DrillWord("perché", "为什么", "why"),
            DrillWord("università", "大学", "university"),
            DrillWord("qualità", "质量", "quality"),
            DrillWord("lunedì", "星期一", "Monday"),
            DrillWord("ventitré", "二十三", "twenty-three"),
            DrillWord("società", "公司", "company"),
            DrillWord("può", "能够", "can"),
            DrillWord("già", "已经", "already"),
            DrillWord("un'altra", "另一个（阴性）", "another"),
        ]
    )

    /// 现在支持的语言。顺序就是界面上的顺序。
    static let catalog: [TypingLanguage] = [.german, .french, .spanish, .italian]

    static func language(id: String) -> TypingLanguage? {
        catalog.first { $0.id == id }
    }
}
