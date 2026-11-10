//  ClipboardService.swift
//  Aurora — 剪贴板历史（参考 Maccy：多格式、去重、忽略规则、固定项）
//
//  设计取舍：
//  · 只在 changeCount 变化时读一次剪贴板，0.6 秒轮询，开销可以忽略；
//  · 图片与富文本落成文件，JSON 里只存索引，历史再长也不会把偏好写爆；
//  · 记住原始 RTF，粘贴时能保留格式；「粘贴为纯文本」只写 string。

import AppKit
import Carbon.HIToolbox
import Combine
import CryptoKit

enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case text, rich, link, image, file, color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return T("文本")
        case .rich: return T("富文本")
        case .link: return T("链接")
        case .image: return T("图片")
        case .file: return T("文件")
        case .color: return T("颜色")
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .rich: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }
}

enum ClipFilter: String, CaseIterable, Identifiable {
    case all, pinned, text, link, image, file, color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return T("全部")
        case .pinned: return T("固定")
        case .text: return T("文本")
        case .link: return T("链接")
        case .image: return T("图片")
        case .file: return T("文件")
        case .color: return T("颜色")
        }
    }
}

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipKind
    var text: String
    var imageFile: String?
    var rtfFile: String?
    var colorHex: String?
    var date: Date
    var pinned: Bool
    var source: String
    var sourceBundle: String
    var copies: Int
    var byteCount: Int
    var digest: String

    init(
        id: UUID = UUID(),
        kind: ClipKind,
        text: String = "",
        imageFile: String? = nil,
        rtfFile: String? = nil,
        colorHex: String? = nil,
        date: Date = Date(),
        pinned: Bool = false,
        source: String = "",
        sourceBundle: String = "",
        copies: Int = 1,
        byteCount: Int = 0,
        digest: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.rtfFile = rtfFile
        self.colorHex = colorHex
        self.date = date
        self.pinned = pinned
        self.source = source
        self.sourceBundle = sourceBundle
        self.copies = copies
        self.byteCount = byteCount
        self.digest = digest
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFile, rtfFile, colorHex, date, pinned
        case source, sourceBundle, copies, byteCount, digest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(ClipKind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFile = try container.decodeIfPresent(String.self, forKey: .imageFile)
        rtfFile = try container.decodeIfPresent(String.self, forKey: .rtfFile)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        sourceBundle = try container.decodeIfPresent(String.self, forKey: .sourceBundle) ?? ""
        copies = try container.decodeIfPresent(Int.self, forKey: .copies) ?? 1
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        digest = try container.decodeIfPresent(String.self, forKey: .digest) ?? ""
    }

    var displaySource: String { source.isEmpty ? T("未知") : source }

    var isTextual: Bool { kind == .text || kind == .rich || kind == .link }

    var preview: String {
        switch kind {
        case .text, .rich, .link:
            let flat = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
        case .file:
            let names = text.split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            if names.count == 1 { return names[0] }
            return TF("%@ 等 %d 个文件", names.first ?? "", names.count - 1)
        case .image:
            return T("图片")
        case .color:
            return colorHex ?? T("颜色")
        }
    }

    var sizeLabel: String? {
        guard byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

@MainActor
final class ClipboardService: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var filter: ClipFilter = .all
    @Published private(set) var isEnabled: Bool
    /// 系统进入安全输入（密码框）时暂停记录，避免把密码写进历史
    @Published private(set) var isPausedBySecureInput: Bool = false
    /// 忽略「下一次」复制（Maccy 的 ignoreOnlyNextEvent）
    @Published var ignoreNextCopy: Bool = false

    @Published var limit: Int { didSet { persistSettings() } }
    @Published var dedupe: Bool { didSet { persistSettings() } }
    @Published var captureText: Bool { didSet { persistSettings() } }
    @Published var captureImages: Bool { didSet { persistSettings() } }
    @Published var captureFiles: Bool { didSet { persistSettings() } }
    @Published var ignoreConfidential: Bool { didSet { persistSettings() } }
    /// 单击记录直接粘贴到上一个 App（Maccy 的 pasteByDefault）
    @Published var tapToPaste: Bool { didSet { persistSettings() } }

    @Published private(set) var ignoredApps: [String] = []
    @Published private(set) var ignoredPatterns: [String] = []
    @Published private(set) var byteTotal: Int = 0

    private var moduleEnabled = true
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let storeURL: URL
    private let imageDir: URL
    private let rtfDir: URL
    private let thumbCache = NSCache<NSString, NSImage>()

    private static let confidentialTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "net.antelle.keeweb"
    ]

    var filtered: [ClipItem] {
        var base = items
        switch filter {
        case .all:
            break
        case .pinned:
            base = base.filter(\.pinned)
        case .text:
            base = base.filter { $0.kind == .text || $0.kind == .rich }
        case .link:
            base = base.filter { $0.kind == .link }
        case .image:
            base = base.filter { $0.kind == .image }
        case .file:
            base = base.filter { $0.kind == .file }
        case .color:
            base = base.filter { $0.kind == .color }
        }
        if !query.isEmpty {
            let needle = query.trimmingCharacters(in: .whitespaces)
            base = base.filter {
                $0.text.localizedCaseInsensitiveContains(needle)
                    || $0.preview.localizedCaseInsensitiveContains(needle)
                    || ($0.colorHex?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    var pinnedItems: [ClipItem] { filtered.filter(\.pinned) }

    var pinnedCount: Int { items.filter(\.pinned).count }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora", isDirectory: true)
        storeURL = support.appendingPathComponent("clipboard.json")
        imageDir = support.appendingPathComponent("clips", isDirectory: true)
        rtfDir = support.appendingPathComponent("clips-rtf", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rtfDir, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "clipboard.enabled") as? Bool ?? true
        limit = defaults.object(forKey: "clipboard.limit") as? Int ?? 100
        dedupe = defaults.object(forKey: "clipboard.dedupe") as? Bool ?? true
        captureText = defaults.object(forKey: "clipboard.captureText") as? Bool ?? true
        captureImages = defaults.object(forKey: "clipboard.captureImages") as? Bool ?? true
        captureFiles = defaults.object(forKey: "clipboard.captureFiles") as? Bool ?? true
        ignoreConfidential = defaults.object(forKey: "clipboard.ignoreConfidential") as? Bool ?? true
        tapToPaste = defaults.object(forKey: "clipboard.tapToPaste") as? Bool ?? false
        ignoredApps = defaults.stringArray(forKey: "clipboard.ignoredApps") ?? []
        ignoredPatterns = defaults.stringArray(forKey: "clipboard.ignoredPatterns") ?? []

        load()
        lastChangeCount = NSPasteboard.general.changeCount
        if isEnabled { start() }
    }

    deinit { timer?.invalidate() }

    // MARK: - 轮询

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "clipboard.enabled")
        if enabled && moduleEnabled { start() } else { timer?.invalidate(); timer = nil }
    }

    /// 重置所有设置时同步内存状态（偏好已被清空）
    func resetSettings() {
        limit = 100
        dedupe = true
        captureText = true
        captureImages = true
        captureFiles = true
        ignoreConfidential = true
        tapToPaste = false
        ignoreNextCopy = false
        ignoredApps = []
        ignoredPatterns = []
        query = ""
        filter = .all
        setEnabled(true)
    }

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        lastChangeCount = NSPasteboard.general.changeCount
        if enabled && isEnabled { start() } else { timer?.invalidate(); timer = nil }
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        let secure = IsSecureEventInputEnabled()
        if secure != isPausedBySecureInput { isPausedBySecureInput = secure }
        guard !secure else {
            // 安全输入期间只同步 changeCount，不落库
            lastChangeCount = NSPasteboard.general.changeCount
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        capture(from: pasteboard)
    }

    private func capture(from pasteboard: NSPasteboard) {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier ?? ""
        let sourceName = app?.localizedName ?? ""

        if !bundle.isEmpty, ignoredApps.contains(bundle) { return }

        let types = Set(pasteboard.types ?? [])
        if ignoreConfidential, !Set(types.map(\.rawValue)).isDisjoint(with: Self.confidentialTypes) { return }

        if ignoreNextCopy {
            ignoreNextCopy = false
            return
        }

        // 文件
        if captureFiles {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
               !urls.isEmpty {
                insert(
                    kind: .file,
                    text: urls.map(\.path).joined(separator: "\n"),
                    byteCount: urls.reduce(0) { $0 + ($1 as NSURL).fileSize },
                    source: sourceName,
                    bundle: bundle
                )
                return
            }
        }

        // 图片
        if captureImages,
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: data) {
            guard let png = pngData(from: image) else { return }
            let name = "\(UUID().uuidString).png"
            let url = imageDir.appendingPathComponent(name)
            guard (try? png.write(to: url)) != nil else { return }
            insert(
                kind: .image,
                imageFile: name,
                byteCount: png.count,
                source: sourceName,
                bundle: bundle,
                digest: sha256(png)
            )
            return
        }

        // 颜色（NSColor 面板 / 拾色器复制出来的）
        if let colors = pasteboard.readObjects(forClasses: [NSColor.self]) as? [NSColor],
           let color = colors.first?.usingColorSpace(.sRGB) {
            let hex = color.hexString
            insert(
                kind: .color,
                text: hex,
                colorHex: hex,
                byteCount: 0,
                source: sourceName,
                bundle: bundle
            )
            return
        }

        guard captureText else { return }

        // 富文本：RTF 优先，其次把 HTML 转成 RTF 存一份
        var rtfData = pasteboard.data(forType: .rtf)
        if rtfData == nil,
           let html = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: html, documentAttributes: nil),
           attributed.length > 0 {
            let range = NSRange(location: 0, length: attributed.length)
            rtfData = attributed.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }

        let attributedText = rtfData
            .flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        var plain = pasteboard.string(forType: .string) ?? attributedText ?? ""
        plain = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }
        guard !matchesIgnoredPattern(plain) else { return }

        if let rtfData, rtfData.count > 0 {
            let name = "\(UUID().uuidString).rtf"
            let url = rtfDir.appendingPathComponent(name)
            try? rtfData.write(to: url)
            insert(
                kind: .rich,
                text: plain,
                rtfFile: name,
                byteCount: rtfData.count + plain.utf8.count,
                source: sourceName,
                bundle: bundle
            )
            return
        }

        let isLink = plain.hasPrefix("http://") || plain.hasPrefix("https://")
        insert(
            kind: isLink ? .link : .text,
            text: plain,
            byteCount: plain.utf8.count,
            source: sourceName,
            bundle: bundle
        )
    }

    private func insert(
        kind: ClipKind,
        text: String = "",
        imageFile: String? = nil,
        rtfFile: String? = nil,
        colorHex: String? = nil,
        byteCount: Int,
        source: String,
        bundle: String,
        digest: String = ""
    ) {
        if !text.isEmpty, matchesIgnoredPattern(text) { return }

        if dedupe, let index = items.firstIndex(where: { existing in
            guard existing.kind == kind else { return false }
            switch kind {
            case .image:
                // 旧记录没有 digest，不能只比空字符串，否则任意图片都会被判成重复
                return !digest.isEmpty && existing.digest == digest
            case .color:
                return existing.colorHex == colorHex
            case .text, .rich, .link, .file:
                return existing.text == text
            }
        }) {
            items[index].date = Date()
            items[index].copies += 1
            items[index].source = source
            items[index].sourceBundle = bundle
            if !items[index].pinned {
                let moved = items.remove(at: index)
                items.insert(moved, at: 0)
            }
            // 去重时新写入的图片 / RTF 文件不会再被引用，顺手删掉
            if let imageFile {
                try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(imageFile))
            }
            if let rtfFile {
                try? FileManager.default.removeItem(at: rtfDir.appendingPathComponent(rtfFile))
            }
            save()
            return
        }

        items.insert(ClipItem(
            kind: kind,
            text: text,
            imageFile: imageFile,
            rtfFile: rtfFile,
            colorHex: colorHex,
            pinned: false,
            source: source,
            sourceBundle: bundle,
            byteCount: byteCount,
            digest: digest
        ), at: 0)
        trim()
        save()
    }

    private func matchesIgnoredPattern(_ text: String) -> Bool {
        for pattern in ignoredPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }

    private func trim() {
        byteTotal = items.reduce(0) { $0 + $1.byteCount }
        guard items.count > limit else { return }
        var removable = items.filter { !$0.pinned }
        while items.count > limit, let last = removable.popLast() {
            guard let index = items.firstIndex(where: { $0.id == last.id }) else { continue }
            removeFiles(items[index])
            items.remove(at: index)
        }
    }

    // MARK: - 操作

    func copy(_ item: ClipItem, plainText: Bool = false) {
        let current = items.first(where: { $0.id == item.id }) ?? item
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch current.kind {
        case .text, .link:
            pasteboard.setString(current.text, forType: .string)
        case .rich:
            if !plainText, let data = rtfData(for: current) {
                pasteboard.setData(data, forType: .rtf)
            }
            pasteboard.setString(current.text, forType: .string)
        case .image:
            if let url = imageURL(for: current), let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        case .file:
            let urls = current.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            pasteboard.writeObjects(urls as [NSURL])
        case .color:
            if let hex = current.colorHex, let color = NSColor(hexString: hex) {
                pasteboard.writeObjects([color])
                pasteboard.setString(hex, forType: .string)
            }
        }
        if pasteboard.changeCount != lastChangeCount { lastChangeCount = pasteboard.changeCount }
    }

    func copyPlainText(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func paste(_ item: ClipItem, plainText: Bool = false) {
        copy(item, plainText: plainText)
        // 模拟 ⌘V：面板收起动画约 0.18s，等它把 key window 交还给上一个 App 再按
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            let source = CGEventSource(stateID: .combinedSessionState)
            // 抑制期间只放行鼠标，避免连发两次 ⌘V
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval
            )
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cgSessionEventTap)
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        save()
    }

    func delete(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        removeFiles(items[index])
        items.remove(at: index)
        byteTotal = items.reduce(0) { $0 + $1.byteCount }
        save()
    }

    func clearUnpinned() {
        for item in items where !item.pinned { removeFiles(item) }
        items.removeAll { !$0.pinned }
        byteTotal = items.reduce(0) { $0 + $1.byteCount }
        save()
    }

    func clearAll() {
        for item in items { removeFiles(item) }
        items.removeAll()
        byteTotal = 0
        save()
    }

    func updateText(_ text: String, for item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if items[index].kind == .rich, let file = items[index].rtfFile {
            try? FileManager.default.removeItem(at: rtfDir.appendingPathComponent(file))
            items[index].rtfFile = nil
        }
        items[index].kind = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? .link : .text
        items[index].text = trimmed
        items[index].byteCount = trimmed.utf8.count
        items[index].date = Date()
        save()
    }

    func item(with id: UUID) -> ClipItem? { items.first { $0.id == id } }

    /// 第 N 个固定项（⌘1–⌘9 用）
    func pinnedItem(at index: Int) -> ClipItem? {
        let pinned = filtered.filter(\.pinned)
        guard index >= 0, index < pinned.count else { return nil }
        return pinned[index]
    }

    func shortcutIndex(for item: ClipItem) -> Int? {
        guard item.pinned else { return nil }
        let pinned = filtered.filter(\.pinned)
        guard let index = pinned.firstIndex(where: { $0.id == item.id }), index < 9 else { return nil }
        return index + 1
    }

    func reveal(_ item: ClipItem) {
        switch item.kind {
        case .file:
            let urls = item.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .image:
            if let url = imageURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        default:
            break
        }
    }

    // MARK: - 忽略规则

    func ignoreApp(bundle: String, name: String) {
        guard !bundle.isEmpty, !ignoredApps.contains(bundle) else { return }
        ignoredApps.append(bundle)
        UserDefaults.standard.set(ignoredApps, forKey: "clipboard.ignoredApps")
        items.removeAll { $0.sourceBundle == bundle }
        save()
    }

    func removeIgnoredApp(_ bundle: String) {
        ignoredApps.removeAll { $0 == bundle }
        UserDefaults.standard.set(ignoredApps, forKey: "clipboard.ignoredApps")
    }

    @discardableResult
    func addIgnorePattern(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, (try? NSRegularExpression(pattern: trimmed)) != nil else { return false }
        guard !ignoredPatterns.contains(trimmed) else { return true }
        ignoredPatterns.append(trimmed)
        UserDefaults.standard.set(ignoredPatterns, forKey: "clipboard.ignoredPatterns")
        return true
    }

    func removeIgnorePattern(_ pattern: String) {
        ignoredPatterns.removeAll { $0 == pattern }
        UserDefaults.standard.set(ignoredPatterns, forKey: "clipboard.ignoredPatterns")
    }

    // MARK: - 文件

    func imageURL(for item: ClipItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        return imageDir.appendingPathComponent(file)
    }

    func rtfData(for item: ClipItem) -> Data? {
        guard let file = item.rtfFile else { return nil }
        return try? Data(contentsOf: rtfDir.appendingPathComponent(file))
    }

    func attributed(for item: ClipItem) -> NSAttributedString? {
        guard let data = rtfData(for: item) else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    /// 列表缩略图：同一张图会反复渲染，缓存一份避免滚动掉帧
    func thumbnail(for item: ClipItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    private func removeFiles(_ item: ClipItem) {
        if let file = item.imageFile {
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(file))
        }
        if let file = item.rtfFile {
            try? FileManager.default.removeItem(at: rtfDir.appendingPathComponent(file))
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 持久化

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(limit, forKey: "clipboard.limit")
        defaults.set(dedupe, forKey: "clipboard.dedupe")
        defaults.set(captureText, forKey: "clipboard.captureText")
        defaults.set(captureImages, forKey: "clipboard.captureImages")
        defaults.set(captureFiles, forKey: "clipboard.captureFiles")
        defaults.set(ignoreConfidential, forKey: "clipboard.ignoreConfidential")
        defaults.set(tapToPaste, forKey: "clipboard.tapToPaste")
        trim()
        save()
    }

    private func save() {
        byteTotal = items.reduce(0) { $0 + $1.byteCount }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = decoded
        byteTotal = items.reduce(0) { $0 + $1.byteCount }
    }
}

// MARK: - NSColor / NSURL 辅助

extension NSColor {
    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension NSURL {
    var fileSize: Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path ?? ""),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }
}
