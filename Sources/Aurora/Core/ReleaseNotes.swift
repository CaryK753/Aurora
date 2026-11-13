//  ReleaseNotes.swift
//  Aurora — 更新说明的解析与「新功能」版本记录
//
//  GitHub Release 的正文既可能是 Markdown，也可能是整段 HTML（在网页编辑器里直接写标签，
//  或者把生成的 HTML 粘进去）。以前直接把原文塞进 NSAlert，用户看到的是 `<h2>`、
//  `<li>` 这类标签。这里统一走「先归一成 Markdown，再按行解析」的两步流程，
//  产出一份结构化说明，供更新弹窗（摘要）与「新功能」窗口（完整内容）共用。

import Foundation

// MARK: - 模型

/// 一段文字。`strong` 对应 HTML 的 <strong>/<b> 或 Markdown 的 **…**
struct NoteRun: Hashable {
    var text: String
    var strong: Bool = false
}

enum NoteBlockKind: Hashable {
    case heading(Int)
    case paragraph
    case bullet
}

/// 归一化之后的一行/一块内容
struct NoteBlock: Identifiable, Hashable {
    let id = UUID()
    var kind: NoteBlockKind
    var runs: [NoteRun]

    var text: String { runs.map(\.text).joined() }
}

struct ReleaseNotes {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        /// 粗体引导出来的小标题（「**罗技鼠标设置向导**：…」里的前半句），没有就是空
        var title: String = ""
        var detailRuns: [NoteRun] = []

        var detail: String {
            detailRuns.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// 一行摘要：优先用小标题，没小标题就用正文开头
        var summary: String {
            if !title.isEmpty { return title }
            let text = detail.replacingOccurrences(of: "\n", with: " ")
            return text.count > 48 ? String(text.prefix(48)) + "…" : text
        }
    }

    struct Section: Identifiable, Hashable {
        let id = UUID()
        /// 「新增」「修复」之类的小标题，历史版本可能没有
        var title: String = ""
        var items: [Item] = []
    }

    var version: String = ""
    /// 版本标题（## Aurora v1.4.0），窗口里一般不用，留着给调试看
    var title: String = ""
    /// 首段，通常是这次更新的主题（「存储、显示器与鼠标。」）
    var headline: String = ""
    var sections: [Section] = []

    var allItems: [Item] { sections.flatMap(\.items) }
    var itemCount: Int { allItems.count }
    var isEmpty: Bool { allItems.isEmpty }

    /// 更新弹窗里的几条要点
    func highlights(limit: Int = 4) -> [String] {
        allItems
            .map { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - 解析

enum ReleaseNotesParser {

    static func parse(_ raw: String, version: String = "") -> ReleaseNotes {
        var notes = ReleaseNotes()
        notes.version = version
        var blocks = blocks(from: markdown(from: raw))

        // 开头的版本标题当标题用，不进正文
        if let first = blocks.first, case .heading = first.kind,
           isVersionHeading(first.text, version: version) {
            notes.title = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.removeFirst()
        }
        // 紧跟其后的第一段是这次更新的主题
        if let first = blocks.first, first.kind == .paragraph {
            let headline = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if headline.count <= 120 {
                notes.headline = headline
                blocks.removeFirst()
            }
        }

        var section = ReleaseNotes.Section()
        func flush() {
            if !section.items.isEmpty { notes.sections.append(section) }
            section = ReleaseNotes.Section()
        }

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                let title = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, level > 1 else { continue }
                guard !isVersionHeading(title, version: version) else { continue }
                flush()
                section.title = title
            case .paragraph, .bullet:
                if let item = item(from: block) {
                    section.items.append(item)
                }
            }
        }
        flush()
        return notes
    }

    /// 版本标题：「Aurora v1.4.0」「v1.4.0」「更新日志」这类
    private static func isVersionHeading(_ text: String, version: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower == "changelog" || lower == "更新日志" || lower == "更新说明" { return true }
        let compact = lower.replacingOccurrences(of: " ", with: "")
        if compact.hasPrefix("v"), compact.dropFirst().first?.isNumber == true { return true }
        if lower.contains("aurora"), lower.contains(where: \.isNumber) { return true }
        if !version.isEmpty, compact.contains(version.lowercased()) { return true }
        return false
    }

    private static func item(from block: NoteBlock) -> ReleaseNotes.Item? {
        var runs = block.runs
        while let first = runs.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runs.removeFirst()
        }
        while let last = runs.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runs.removeLast()
        }
        guard !runs.isEmpty else { return nil }

        var item = ReleaseNotes.Item()

        // 「**小标题**：正文」——粗体领起的那一段当小标题
        if runs.count > 1, runs[0].strong {
            let head = runs[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty, head.count <= 40 {
                item.title = head
                runs.removeFirst()
                if var first = runs.first {
                    var text = first.text
                    // 去掉标题后紧跟的冒号 / 破折号
                    while let character = text.first, "：:，,、—-–·→ ".contains(character) {
                        text.removeFirst()
                    }
                    first.text = text
                    runs[0] = first
                }
            }
        }

        while let first = runs.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runs.removeFirst()
        }
        item.detailRuns = runs
        if item.title.isEmpty, item.detail.isEmpty { return nil }
        return item
    }

    // MARK: 归一化成 Markdown

    /// HTML → Markdown（纯 Markdown 原样保留，只解实体）
    static func markdown(from raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = replacing(text, #"<!--[\s\S]*?-->"#, "")

        // 行内代码里的东西（`<h2>`、`<li>` 这类被讨论的标签）先摘出来，
        // 否则会被当成真标签：既误判成 HTML，又会被后面的去标签规则吃掉
        var codes: [String] = []
        let protected = inlineSegments(text).map { segment -> String in
            guard segment.code else { return segment.text }
            codes.append(segment.text)
            return "\(codeToken)\(codes.count - 1)\(codeToken)"
        }.joined()

        guard containsHTML(protected) else {
            return restoreInlineCode(decodeEntities(normalizeMarkdown(protected)), codes: codes)
        }

        var html = protected
        let rules: [(String, String)] = [
            (#"<br\s*/?>"#, "\n"),
            (#"<hr\s*/?>"#, "\n"),
            (#"<h1[^>]*>"#, "\n# "),
            (#"<h2[^>]*>"#, "\n## "),
            (#"<h3[^>]*>"#, "\n### "),
            (#"<h(4|5|6)[^>]*>"#, "\n#### "),
            (#"</h[1-6]>"#, "\n"),
            (#"<li[^>]*>"#, "\n- "),
            (#"</li>"#, "\n"),
            (#"</?(p|div|ul|ol|blockquote|section|details|summary|table|thead|tbody|tr|figure|figcaption|dl|dt|dd)(\s[^>]*)?>"#, "\n"),
            (#"<(strong|b)(\s[^>]*)?>"#, "**"),
            (#"</(strong|b)>"#, "**"),
            (#"<(em|i)(\s[^>]*)?>"#, ""),
            (#"</(em|i)>"#, ""),
            (#"<code[^>]*>"#, ""),
            (#"</code>"#, ""),
            (#"<img[^>]*>"#, ""),
            (#"</?(a|span|font|small|big|mark|u|s|del|ins|sub|sup|time|abbr|picture|source|video|audio)(\s[^>]*)?>"#, ""),
            (#"<[^>]+>"#, ""),
        ]
        for (pattern, replacement) in rules {
            html = replacing(html, pattern, replacement)
        }
        return restoreInlineCode(decodeEntities(normalizeMarkdown(html)), codes: codes)
    }

    /// 行内代码的占位符（不会出现在正常文本里，也不会被正则规则动到）
    private static let codeToken = "\u{0001}"

    /// 还原行内代码，并**连反引号一起放回去**：后面的 runs 解析靠它区分
    /// 「文字」与「不该被当成标签处理的代码」，否则 `<h2>` 这种被讨论的标签会被当标签删掉
    private static func restoreInlineCode(_ text: String, codes: [String]) -> String {
        guard !codes.isEmpty else { return text }
        guard let regex = try? NSRegularExpression(pattern: "\(codeToken)(\\d+)\(codeToken)") else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let indexRange = Range(match.range(at: 1), in: result),
                  let index = Int(result[indexRange]), codes.indices.contains(index) else { continue }
            result.replaceSubrange(whole, with: "`\(codes[index])`")
        }
        return result
    }

    /// 按反引号把一行拆成「普通文字 / 行内代码」两段，代码不跨行
    static func inlineSegments(_ text: String) -> [(text: String, code: Bool)] {
        var segments: [(text: String, code: Bool)] = []
        var buffer = ""
        var inCode = false
        var index = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append((buffer, inCode))
            buffer = ""
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                flush()
                inCode.toggle()
                index = text.index(after: index)
                continue
            }
            if character == "\n", inCode {
                flush()
                inCode = false
                segments.append(("\n", false))
                index = text.index(after: index)
                continue
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        return segments
    }

    private static func containsHTML(_ text: String) -> Bool {
        text.range(of: #"<\s*/?\s*(h[1-6]|p|div|ul|ol|li|br|strong|b|em|i|code|pre|table|blockquote|a|img|section|details)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 收掉 HTML 转换留下的多余空行与行尾空白
    private static func normalizeMarkdown(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                var line = line
                while line.contains("  ") { line = line.replacingOccurrences(of: "  ", with: " ") }
                return line.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }

    private static func replacing(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: Markdown → 块

    static func blocks(from markdown: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var inFence = false
        var blankSeen = false
        /// HTML 的 <li><p>…</p></li> 会先留下一个空的列表标记行，下一段才是这一条的内容
        var pendingBullet = false

        func appendParagraph(_ runs: [NoteRun]) {
            guard !runs.map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if pendingBullet {
                blocks.append(NoteBlock(kind: .bullet, runs: runs))
                pendingBullet = false
                return
            }
            // 没有空行时，紧接着上一块的正文算同一块（Markdown 里列表项的续行就是这样）
            if !blankSeen, let last = blocks.last, last.kind == .paragraph || last.kind == .bullet {
                var merged = last.runs
                if let tail = merged.last, !tail.text.hasSuffix(" ") { merged.append(NoteRun(text: " ")) }
                merged.append(contentsOf: runs)
                blocks[blocks.count - 1] = NoteBlock(kind: last.kind, runs: merged)
            } else {
                blocks.append(NoteBlock(kind: .paragraph, runs: runs))
            }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                blankSeen = true
                continue
            }
            // 分隔线 / 孤零零的列表标记
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { continue }
            if line.count <= 3, line.allSatisfy({ "-*+•".contains($0) }) {
                pendingBullet = true
                blankSeen = false
                continue
            }
            // 表格：拆成「a · b · c」一行
            if line.hasPrefix("|") {
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                let cells = line.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !cells.isEmpty else { continue }
                line = cells.joined(separator: " · ")
            }
            // 引用
            while line.hasPrefix("> ") { line.removeFirst(2); line = line.trimmingCharacters(in: .whitespaces) }

            var kind: NoteBlockKind = .paragraph
            var body = line

            if let heading = headingBody(line) {
                kind = .heading(heading.level)
                body = heading.text
            } else if let bullet = bulletBody(line) {
                kind = .bullet
                body = bullet
            }

            let runs = runs(from: body)
            guard !runs.map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            switch kind {
            case .paragraph:
                appendParagraph(runs)
            case .heading(let level):
                pendingBullet = false
                blocks.append(NoteBlock(kind: .heading(level), runs: runs))
            case .bullet:
                pendingBullet = false
                blocks.append(NoteBlock(kind: .bullet, runs: runs))
            }
            blankSeen = false
        }
        return blocks
    }

    private static func headingBody(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard level >= 1, level <= 6 else { return nil }
        guard index == line.endIndex || line[index] == " " else { return nil }
        return (level, String(line[index...]).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        // 1. / 1) 这样的有序列表
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 行内样式 → runs（只认粗体；行内代码原样保留，链接留文字）
    static func runs(from line: String) -> [NoteRun] {
        var runs: [NoteRun] = []
        for segment in inlineSegments(line) {
            if segment.code {
                if !segment.text.isEmpty { runs.append(NoteRun(text: segment.text)) }
                continue
            }
            var text = replacing(segment.text, #"!\[[^\]]*\]\([^)]*\)"#, "")
            text = replacing(text, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
            text = replacing(text, #"<[^>]+>"#, "")
            runs.append(contentsOf: styledRuns(text))
        }
        return runs
    }

    private static func styledRuns(_ text: String) -> [NoteRun] {
        var runs: [NoteRun] = []
        var buffer = ""
        var strong = false
        var index = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(NoteRun(text: buffer, strong: strong))
            buffer = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("**") {
                flush()
                strong.toggle()
                index = text.index(index, offsetBy: 2)
                continue
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return runs
    }

    // MARK: 实体

    static func decodeEntities(_ text: String) -> String {
        var out = text
        let named = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&middot;": "·", "&bull;": "•", "&times;": "×", "&copy;": "©", "&reg;": "®",
            "&trade;": "™", "&laquo;": "«", "&raquo;": "»", "&deg;": "°",
        ]
        for (key, value) in named {
            out = out.replacingOccurrences(of: key, with: value, options: .caseInsensitive)
        }
        out = numericEntities(#"&#(\d{1,7});"#, in: out) { UInt32($0) }
        out = numericEntities(#"&#[xX]([0-9a-fA-F]{1,6});"#, in: out) { UInt32($0, radix: 16) }
        return out
    }

    private static func numericEntities(_ pattern: String, in text: String, value: (String) -> UInt32?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let digits = Range(match.range(at: 1), in: result),
                  let code = value(String(result[digits])),
                  let scalar = UnicodeScalar(code) else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return result
    }
}

// MARK: - 版本记录 / 本地更新说明

/// 「新功能」窗口的内容来源与「看过没有」的记录
enum ReleaseNotesStore {
    static let seenVersionKey = "whatsNew.seenVersion"
    private static let cacheKey = "whatsNew.remoteNotes"
    /// 缓存最近几个远端版本，够用又不至于把 preferences 撑大
    private static let cacheLimit = 6

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// 当前版本要不要在启动时弹「新功能」：每个版本只弹一次
    static func shouldShow(version: String = currentVersion) -> Bool {
        guard !version.isEmpty else { return false }
        let seen = UserDefaults.standard.string(forKey: seenVersionKey)
        return normalize(seen ?? "") != normalize(version)
    }

    static func markSeen(version: String = currentVersion) {
        guard !version.isEmpty else { return }
        UserDefaults.standard.set(version, forKey: seenVersionKey)
    }

    /// 当前版本的更新说明：优先用包里自带的 CHANGELOG（离线可用、和版本严格对应），
    /// 没有这一版时用更新检查时缓存下来的 Release 正文
    static func notes(for version: String = currentVersion) -> ReleaseNotes? {
        guard !version.isEmpty else { return nil }
        if let body = changelogSection(for: version) {
            let notes = ReleaseNotesParser.parse(body, version: version)
            if !notes.isEmpty { return notes }
        }
        if let body = cachedRemoteNotes(for: version) {
            let notes = ReleaseNotesParser.parse(body, version: version)
            if !notes.isEmpty { return notes }
        }
        return nil
    }

    // MARK: CHANGELOG

    /// CHANGELOG 里最新的版本号（`## v1.4.0` 的第一节）
    static func latestChangelogVersion() -> String? {
        guard let url = changelogURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.hasPrefix("## ") {
            let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard let first = title.split(separator: " ").first else { continue }
            let version = normalize(String(first))
            if version.first?.isNumber == true { return version }
        }
        return nil
    }

    /// 开发预览用：`swift build` 出来的可执行文件没有 Info.plist，版本号为空，
    /// 这时用 CHANGELOG 最新的一节来渲染窗口
    static func previewContent() -> (version: String, notes: ReleaseNotes?) {
        let version = currentVersion.isEmpty ? (latestChangelogVersion() ?? "") : currentVersion
        return (version, notes(for: version))
    }

    static func changelogURL() -> URL? {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") { return url }
        if let base = Bundle.main.resourceURL {
            let url = base.appendingPathComponent("CHANGELOG.md")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // 开发期（swift run / swift build 产物）仓库路径兜底
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // Aurora
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("CHANGELOG.md")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// 从 CHANGELOG 里取出某个版本的正文（`## v1.4.0` 到下一个 `## ` 之间）
    static func changelogSection(for version: String) -> String? {
        guard let url = changelogURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let target = normalize(version)
        var capturing = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if capturing { break }
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let candidate = normalize(String(title.split(separator: " ").first ?? ""))
                if candidate == target { capturing = true }
                continue
            }
            if capturing { lines.append(line) }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: 远端正文缓存

    static func cacheRemoteNotes(_ body: String, version: String) {
        let key = normalize(version)
        guard !body.isEmpty, !key.isEmpty else { return }
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        cache[key] = body
        if cache.count > cacheLimit {
            // 超出上限就丢掉最早写进来的几项（字典无序，按体积兜底即可）
            let drop = cache.count - cacheLimit
            for key in cache.keys.sorted().prefix(drop) { cache.removeValue(forKey: key) }
        }
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }

    static func cachedRemoteNotes(for version: String) -> String? {
        let cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        return cache[normalize(version)]
    }

    private static func normalize(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        return text
    }
}
