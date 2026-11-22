//  KeyboardLayoutProbe.swift
//  Aurora — 读取系统里的真实键盘布局
//
//  小语种键盘教练不写死「德语 Z 在 Y 的位置」这种结论：直接把系统里的
//  German / French / Spanish / Italian 布局读出来，按物理键位翻译成字符。
//  同时把 ABC 布局上的死键组合扫一遍，得到「ä = ⌥U → A」这类真实打法。

import Carbon.HIToolbox
import Foundation
import LanguageLayoutPlugin

enum KeyboardLayoutProbe {
    /// 当前英文键盘的布局 ID（可能是 ABC、ABC Extended 或用户自建）。
    static let primaryLatinLayoutID = "com.apple.keylayout.ABC"

    /// HIToolbox 的输入源列表不是并发安全的：两次读取撞在一起会直接 abort。
    /// 探测只在主线程按需跑一次，这把锁是最后一道保险。
    private static let lock = NSLock()

    /// 每门语言只探一次：读布局本身只要 1–3 ms，但冷启动第一次枚举输入源要 60 ms 以上。
    /// 缓存也就顺带让「再进一次页面」完全不触发重新排版。
    private static var cache: [String: LayoutSnapshot] = [:]
    /// ABC 布局的组合键表对所有语言都一样，只算一次。
    private static var latinChords: ChordBook?

    /// 读一门语言：键位表 + 组合键表。读不到布局时退回内置表并标记 isFallback。
    static func snapshot(for language: TypingLanguage) -> LayoutSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language.layoutID] { return cached }

        let keys = readKeys(layoutID: language.layoutID)
        let chords = latinChordBook()
        let snapshot = LayoutSnapshot(
            layoutID: language.layoutID,
            languageID: language.id,
            keys: keys,
            chords: chords.isEmpty ? .builtIn(for: language) : chords,
            isFallback: keys.isEmpty
        )
        // 读不到布局时不要缓存，下次进来还能重试（比如用户刚在系统设置里装上）。
        if !keys.isEmpty { cache[language.layoutID] = snapshot }
        return snapshot
    }

    private static func latinChordBook() -> ChordBook {
        if let latinChords { return latinChords }
        let book = chordBook(from: readKeys(layoutID: primaryLatinLayoutID))
        if !book.isEmpty { latinChords = book }
        return book
    }

    // MARK: - 布局数据

    private static func layoutData(_ id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        // includeAllInstalled: true —— 没启用的布局也能读，用户不必先在系统设置里加一遍。
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func readKeys(layoutID: String) -> [UInt16: KeyOutput] {
        guard let data = layoutData(layoutID) else { return [:] }
        var map: [UInt16: KeyOutput] = [:]
        for code in UInt16(0)...UInt16(50) {
            let base = translate(data, keyCode: code, modifiers: 0)
            let shift = translate(data, keyCode: code, modifiers: UInt32(shiftKey))
            // 两个都为空也算「这个位置有键，但按下是死键」（法语 ^ / ¨）：
            // 保留空条目，界面才能把它画成死键而不是画成英文键名。
            map[code] = KeyOutput(base: base ?? "", shift: shift ?? "")
        }
        return map
    }

    /// 按一个物理键，返回它打出来的字符；死键会返回 nil（并留下 dead 状态）。
    private static func translate(_ data: Data, keyCode: UInt16, modifiers: UInt32,
                                  dead: inout UInt32) -> String? {
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let pointer = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(pointer, keyCode, UInt16(kUCKeyActionDown), modifiers >> 8,
                                  UInt32(LMGetKbdType()), 0, &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static func translate(_ data: Data, keyCode: UInt16, modifiers: UInt32) -> String? {
        var dead: UInt32 = 0
        return translate(data, keyCode: keyCode, modifiers: modifiers, dead: &dead)
    }

    // MARK: - 组合键

    /// 扫一遍英文布局：⌥x 与「死键 + 字母」能打出哪些非 ASCII 字符。
    private static func chordBook(from english: [UInt16: KeyOutput]) -> ChordBook {
        guard !english.isEmpty, let data = layoutData(primaryLatinLayoutID) else { return .empty }
        let names = Dictionary(uniqueKeysWithValues: PhysicalKeyboard.rows.flatMap(\.keys).map { ($0.code, $0.name) })
        var chords: [String: Chord] = [:]

        for code in UInt16(0)...UInt16(50) {
            let name = names[code] ?? String(code)
            var dead: UInt32 = 0
            if let output = translate(data, keyCode: code, modifiers: UInt32(optionKey), dead: &dead),
               !output.isEmpty, output.unicodeScalars.contains(where: { !$0.isASCII }) {
                chords[output] = Chord(["⌥\(name)"])
            }
            if let output = translate(data, keyCode: code, modifiers: UInt32(optionKey | shiftKey)),
               !output.isEmpty, output.unicodeScalars.contains(where: { !$0.isASCII }) {
                chords[output] = Chord(["⌥⇧\(name)"])
            }
            guard dead != 0 else { continue }
            // 死键：把后面能接的字母都试一遍，得到「⌥U → A」这种两步组合。
            for letter in UInt16(0)...UInt16(50) {
                let baseName = names[letter] ?? String(letter)
                if let composed = compose(data, dead: dead, keyCode: letter, modifiers: 0),
                   let first = composed.first, !first.isASCII {
                    chords[String(first)] = Chord(["⌥\(name)", baseName], deadKey: true)
                }
                if let composed = compose(data, dead: dead, keyCode: letter, modifiers: UInt32(shiftKey)),
                   let first = composed.first, !first.isASCII {
                    chords[String(first)] = Chord(["⌥\(name)", "⇧\(baseName)"], deadKey: true)
                }
            }
        }
        return ChordBook(chords)
    }

    private static func compose(_ data: Data, dead: UInt32, keyCode: UInt16, modifiers: UInt32) -> String? {
        var state = dead
        guard let output = translate(data, keyCode: keyCode, modifiers: modifiers, dead: &state) else { return nil }
        // 组合失败时系统会把死键字符和字母一起吐出来（如 "´s"），这种不算。
        return output.count == 1 ? output : nil
    }
}
