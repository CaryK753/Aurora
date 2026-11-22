import XCTest
@testable import LanguageLayoutPlugin

final class LanguageLayoutPluginTests: XCTestCase {

    // MARK: - 语言数据

    func testCatalogHasThreeLanguagesWithLayoutIDs() {
        let ids = TypingLanguage.catalog.map(\.id)
        XCTAssertEqual(ids, ["de", "fr", "es"])
        for language in TypingLanguage.catalog {
            XCTAssertFalse(language.words.isEmpty)
            XCTAssertTrue(language.layoutID.hasPrefix("com.apple.keylayout."))
            XCTAssertFalse(language.specialCharacters.isEmpty)
            XCTAssertEqual(language.notes.count, language.notesEN.count)
        }
    }

    /// 练习词里必须真的有本语言的特殊字符，不然练了也没用。
    func testEveryLanguageHasWordsUsingSpecialCharacters() {
        for language in TypingLanguage.catalog {
            let special = Set(language.specialCharacters)
            let used = language.words.flatMap { $0.text.map(String.init) }.filter { special.contains($0) }
            XCTAssertFalse(used.isEmpty, "\(language.id) 的练习词没有特殊字符")
        }
    }

    func testFrenchWordsCoverTheHardCharacters() {
        let text = TypingLanguage.french.words.map(\.text).joined()
        for character in ["é", "è", "ê", "ç", "à"] {
            XCTAssertTrue(text.contains(character), "缺少 \(character)")
        }
    }

    // MARK: - 组合键

    func testGermanFallbackChords() {
        let book = ChordBook.builtIn(for: .german)
        XCTAssertEqual(book.chord(for: "ä")?.steps, ["⌥U", "A"])
        XCTAssertEqual(book.chord(for: "ä")?.isDeadKey, true)
        XCTAssertEqual(book.chord(for: "ß")?.steps, ["⌥S"])
        XCTAssertEqual(book.chord(for: "ß")?.isSingleStroke, true)
        XCTAssertEqual(book.chord(for: "Ä")?.steps, ["⌥U", "⇧A"])
        XCTAssertNil(book.chord(for: "a"))
    }

    func testFrenchAndSpanishFallbackChords() {
        XCTAssertEqual(ChordBook.builtIn(for: .french).chord(for: "œ")?.steps, ["⌥Q"])
        XCTAssertEqual(ChordBook.builtIn(for: .french).chord(for: "ç")?.steps, ["⌥C"])
        XCTAssertEqual(ChordBook.builtIn(for: .spanish).chord(for: "ñ")?.steps, ["⌥N", "N"])
        XCTAssertEqual(ChordBook.builtIn(for: .spanish).chord(for: "¿")?.steps, ["⌥⇧?"])
        XCTAssertTrue(ChordBook.builtIn(for: .spanish).chord(for: "ñ")?.isDeadKey == true)
    }

    func testSpecialCharactersKeepOrderAndDropDuplicates() {
        let book = ChordBook.builtIn(for: .german)
        XCTAssertEqual(book.specialCharacters(in: "Größe"), ["ö", "ß"])
        XCTAssertEqual(book.specialCharacters(in: "Äpfel ä"), ["Ä", "ä"])
        XCTAssertEqual(book.hint(for: "ü"), "⌥U → U")
        XCTAssertNil(book.hint(for: "k"))
    }

    // MARK: - 布局差异

    func testGermanLayoutSwapsZAndYAndAddsUmlauts() {
        let target: [UInt16: KeyOutput] = [
            6: KeyOutput(base: "y", shift: "Y"),
            16: KeyOutput(base: "z", shift: "Z"),
            39: KeyOutput(base: "ä", shift: "Ä"),
            33: KeyOutput(base: "ü", shift: "Ü"),
            41: KeyOutput(base: "ö", shift: "Ö"),
            27: KeyOutput(base: "ß", shift: "?"),
            0: KeyOutput(base: "a", shift: "A"),
        ]
        let deltas = LayoutComparison.compare(target: target)
        let notes = LayoutComparison.notes(deltas)

        XCTAssertTrue(notes.contains { $0.kind == .swapped && $0.character == "Z" && $0.other == "Y" })
        XCTAssertTrue(notes.contains { $0.kind == .added && $0.character == "ä" && $0.other == "'" })
        XCTAssertTrue(notes.contains { $0.kind == .added && $0.character == "ß" && $0.other == "-" })
        // 完全相同与只改 Shift 的键不该出现在提示里。
        XCTAssertFalse(notes.contains { $0.character == "a" })
        XCTAssertFalse(notes.contains { $0.character == "2" })
    }

    func testSwappedPairIsReportedOnce() {
        let target: [UInt16: KeyOutput] = [
            6: KeyOutput(base: "y", shift: "Y"),
            16: KeyOutput(base: "z", shift: "Z"),
        ]
        let swaps = LayoutComparison.notes(LayoutComparison.compare(target: target)).filter { $0.kind == .swapped }
        XCTAssertEqual(swaps.count, 1)
        XCTAssertEqual(swaps.first?.character, "Z")
    }

    func testFrenchLayoutReportsAQandZW() {
        let target: [UInt16: KeyOutput] = [
            12: KeyOutput(base: "a", shift: "A"),
            0: KeyOutput(base: "q", shift: "Q"),
            13: KeyOutput(base: "z", shift: "Z"),
            6: KeyOutput(base: "w", shift: "W"),
        ]
        let notes = LayoutComparison.notes(LayoutComparison.compare(target: target))
        XCTAssertEqual(Set(notes.filter { $0.kind == .swapped }.map(\.character)), ["A", "Z"])
    }

    /// 标点在德语里被挪位置（] 上是 +）不值得提醒，字母换位才值得。
    func testPunctuationNoiseIsDroppedFromNotes() {
        let target: [UInt16: KeyOutput] = [
            30: KeyOutput(base: "+", shift: "*"),
            24: KeyOutput(base: "´", shift: "°"),
            44: KeyOutput(base: "-", shift: "_"),
        ]
        let notes = LayoutComparison.notes(LayoutComparison.compare(target: target))
        XCTAssertTrue(notes.isEmpty, "标点变化不该出现：\(notes)")
    }

    func testNotesPutSwapsBeforeNewCharacters() {
        let target: [UInt16: KeyOutput] = [
            6: KeyOutput(base: "y", shift: "Y"),
            16: KeyOutput(base: "z", shift: "Z"),
            39: KeyOutput(base: "ä", shift: "Ä"),
            27: KeyOutput(base: "ß", shift: "?"),
        ]
        let notes = LayoutComparison.notes(LayoutComparison.compare(target: target))
        XCTAssertEqual(notes.first?.kind, .swapped)
        XCTAssertEqual(notes.filter { $0.kind == .added }.count, 2)
    }

    // MARK: - 练习

    func testDrillAdvancesAndCountsAccuracy() {
        let words = [DrillWord("ö", "x", "x")]
        var engine = DrillEngine(language: .german, words: words)
        engine.start(at: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(engine.update(typed: "o", at: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(engine.mistakes, 1)
        XCTAssertEqual(engine.charStats["ö"]?.wrong, 1)

        XCTAssertTrue(engine.update(typed: "ö", at: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(engine.completedWords, 1)
        XCTAssertEqual(engine.streak, 1)
        XCTAssertEqual(engine.accuracy, 0.5, accuracy: 0.001)

        engine.advance()
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.typed, "")
    }

    func testDeletingDoesNotDoubleCount() {
        let words = [DrillWord("ab", "x", "x")]
        var engine = DrillEngine(language: .german, words: words)
        engine.update(typed: "a")
        engine.update(typed: "ax")
        engine.update(typed: "a")
        engine.update(typed: "ab")
        XCTAssertEqual(engine.keystrokes, 3)
        XCTAssertEqual(engine.mistakes, 1)
        XCTAssertEqual(engine.accuracy, 2.0 / 3.0, accuracy: 0.001)
    }

    func testInputLongerThanTargetIsTruncated() {
        let words = [DrillWord("ab", "x", "x")]
        var engine = DrillEngine(language: .german, words: words)
        engine.update(typed: "abcd")
        XCTAssertEqual(engine.typed, "ab")
        XCTAssertTrue(engine.isCurrentComplete)
    }

    func testWeakCharactersRankByWrongCount() {
        let words = [DrillWord("ää", "x", "x"), DrillWord("öö", "x", "x")]
        var engine = DrillEngine(language: .german, words: words)
        engine.update(typed: "aa")
        engine.advance()
        engine.update(typed: "öx")
        let weak = engine.weakCharacters()
        XCTAssertEqual(weak.first?.character, "ä")
        XCTAssertEqual(weak.first?.stat.wrong, 2)
        XCTAssertTrue(weak.contains { $0.character == "ö" })
    }

    func testProgressAbsorbsSessionsAndMastery() {
        var progress = LanguageProgress()
        var engine = DrillEngine(language: .german, words: [DrillWord("äö", "x", "x")])
        engine.start(at: Date(timeIntervalSince1970: 0))
        engine.update(typed: "äö", at: Date(timeIntervalSince1970: 6))

        progress.absorb(engine, at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(progress.sessions, 1)
        XCTAssertEqual(progress.completedWords, 1)
        XCTAssertGreaterThan(progress.bestWPM, 0)
        XCTAssertEqual(progress.lastPracticed, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(progress.mastery(for: ["ä", "ö"]), 1, accuracy: 0.001)
        XCTAssertEqual(progress.mastery(for: ["ß"]), 0, accuracy: 0.001)

        progress.absorb(engine, at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(progress.stats["ä"]?.correct, 2)
        XCTAssertEqual(progress.sessions, 2)
    }

    func testWeakProgressNeedsAtLeastTwoAttempts() {
        var progress = LanguageProgress()
        progress.stats["ß"] = CharacterStat(correct: 0, wrong: 1)
        XCTAssertTrue(progress.weakCharacters().isEmpty)
        progress.stats["ß"] = CharacterStat(correct: 0, wrong: 2)
        XCTAssertEqual(progress.weakCharacters().first?.character, "ß")
    }

    func testProgressRoundTripsThroughJSON() throws {
        var progress = LanguageProgress()
        progress.stats["ñ"] = CharacterStat(correct: 3, wrong: 1)
        progress.sessions = 2
        let data = try JSONEncoder().encode(progress)
        let loaded = try JSONDecoder().decode(LanguageProgress.self, from: data)
        XCTAssertEqual(loaded, progress)
    }
}
