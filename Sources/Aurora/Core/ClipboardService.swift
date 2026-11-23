//  ClipboardService.swift
//  Aurora — 剪贴板历史（参考 Maccy：多格式、去重、忽略规则、固定项）
//
//  设计取舍：
//  · 只在 changeCount 变化时读一次剪贴板，0.6 秒轮询，开销可以忽略；
//  · 图片与富文本落成文件，SQLite 持久化历史，只有最近 5 条完整记录常驻；
//  · 记住原始 RTF，粘贴时能保留格式；「粘贴为纯文本」只写 string。

import AppKit
import Carbon.HIToolbox
import Combine
import CryptoKit
import ImageIO

enum ClipKind: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum ClipFilter: String, CaseIterable, Identifiable, Sendable {
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

struct ClipItem: Identifiable, Codable, Equatable, Sendable {
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
    var storedPreview: String? = nil
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
        if let storedPreview { return storedPreview }
        switch kind {
        case .text, .rich, .link:
            let head = text.drop(while: { $0.isWhitespace }).prefix(201)
            let flat = String(head.prefix(200)).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return head.count > 200 ? flat + "…" : flat
        case .file:
            let names = text.split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            if names.count == 1 { return String(names[0].prefix(200)) }
            return TF("%@ 等 %d 个文件", String((names.first ?? "").prefix(200)), names.count - 1)
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
    private(set) var recentItems: [ClipItem] = []
    @Published private(set) var historyRevision = 0
    @Published private(set) var historyCount = 0
    @Published private(set) var pinnedCount = 0
    @Published private(set) var storageFailed = false
    @Published var query: String = ""
    @Published var filter: ClipFilter = .all
    @Published private(set) var isEnabled: Bool
    /// 系统进入安全输入（密码框）时暂停记录，避免把密码写进历史
    @Published private(set) var isPausedBySecureInput: Bool = false
    /// 忽略「下一次」复制（Maccy 的 ignoreOnlyNextEvent）
    @Published var ignoreNextCopy: Bool = false

    @Published var limit: Int {
        didSet {
            persistSettings()
            if limit < oldValue, !resettingSettings, let store {
                changeHistory { try store.trim(limit: limit) }
            }
        }
    }
    @Published var dedupe: Bool { didSet { persistSettings() } }
    @Published var captureText: Bool { didSet { persistSettings() } }
    @Published var captureImages: Bool { didSet { persistSettings() } }
    @Published var captureFiles: Bool { didSet { persistSettings() } }
    @Published var ignoreConfidential: Bool { didSet { persistSettings() } }
    /// 单击记录直接粘贴到上一个 App（Maccy 的 pasteByDefault）
    @Published var tapToPaste: Bool { didSet { persistSettings() } }
    /// mini 剪切板贴在输入光标处弹出（取不到光标时退回屏幕中上）
    @Published var anchorAtCaret: Bool { didSet { persistSettings() } }

    @Published private(set) var ignoredApps: [String] = []
    @Published private(set) var ignoredPatterns: [String] = []
    @Published private(set) var byteTotal: Int = 0

    private var moduleEnabled = true
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var store: ClipboardHistoryStore?
    private var resettingSettings = false
    private let historyURL: URL
    private let historyReads = DispatchQueue(label: "aurora.clipboard.page", qos: .utility)
    private let imageDir: URL
    private let rtfDir: URL
    private let thumbnailReads = DispatchQueue(label: "aurora.clipboard.thumbnail", qos: .utility)
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

    func summaries(query: String, filter: ClipFilter, pinnedFirst: Bool = true,
                   limit: Int = 30, offset: Int = 0, includePinned: Bool = false) async -> (rows: [ClipItem], pinned: [ClipItem]) {
        guard store != nil else { return ([], []) }
        let url = historyURL
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await readInBackground(on: historyReads) {
            Result {
                let reader = try ClipboardHistoryStore(url: url, readOnly: true)
                let rows = try reader.page(query: query, filter: filter, pinnedFirst: pinnedFirst, limit: limit, offset: offset)
                let pinned = includePinned ? try reader.page(query: query, filter: filter, pinnedFirst: true, limit: 9, offset: 0) : []
                return (rows, Array(pinned.prefix(while: \.pinned)))
            }
        }
        guard !Task.isCancelled else { return ([], []) }
        switch result {
        case .success(let page): return page
        case .failure: reportStorageError(); return ([], [])
        }
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora", isDirectory: true)
        historyURL = support.appendingPathComponent("clipboard.sqlite3")
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
        anchorAtCaret = defaults.object(forKey: "clipboard.anchorAtCaret") as? Bool ?? true
        ignoredApps = defaults.stringArray(forKey: "clipboard.ignoredApps") ?? []
        ignoredPatterns = defaults.stringArray(forKey: "clipboard.ignoredPatterns") ?? []

        thumbCache.totalCostLimit = 2 * 1024 * 1024
        thumbCache.countLimit = 32
        do {
            let db = try ClipboardHistoryStore(url: historyURL)
            store = db
            do { try db.migrateLegacy(from: support.appendingPathComponent("clipboard.json")) }
            catch { reportStorageError() }
            try refreshHistory(db)
        } catch {
            reportStorageError()
        }
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
        resettingSettings = true
        defer { resettingSettings = false }
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
            guard (try? rtfData.write(to: url)) != nil else { return }
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
        let item = ClipItem(kind: kind, text: text, imageFile: imageFile, rtfFile: rtfFile, colorHex: colorHex,
                            source: source, sourceBundle: bundle, byteCount: byteCount, digest: digest)
        let pending = ClipboardHistoryStore.Attachment(image: imageFile, rtf: rtfFile)
        guard let store else { removeFiles(pending); return }
        let change: (duplicate: Bool, removed: [ClipboardHistoryStore.Attachment])
        do {
            change = try store.record(item, dedupe: dedupe, limit: limit)
        } catch {
            removeFiles(pending)
            reportStorageError()
            return
        }
        if change.duplicate { removeFiles(pending) }
        for attachment in change.removed { removeFiles(attachment) }
        do { try refreshHistory(store) } catch { reportStorageError() }
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

    // MARK: - 操作

    @discardableResult
    func copy(_ item: ClipItem, plainText: Bool = false) -> Bool {
        guard let current = self.item(with: item.id) else { return false }
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
        return true
    }

    func copyPlainText(_ item: ClipItem) {
        guard let item = self.item(with: item.id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func paste(_ item: ClipItem, plainText: Bool = false) {
        guard copy(item, plainText: plainText) else { return }
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
        guard let store else { return }
        changeHistory { try store.setPinned(id: item.id, pinned: !item.pinned, limit: limit) }
    }

    func delete(_ item: ClipItem) {
        guard let store else { return }
        changeHistory { try store.delete(id: item.id) }
    }

    @discardableResult
    func clearUnpinned() -> Bool {
        guard let store else { return false }
        return changeHistory { try store.clear(keepPinned: true) }
    }

    @discardableResult
    func clearAll() -> Bool {
        guard let store else { return false }
        return changeHistory { try store.clear(keepPinned: false) }
    }

    func updateText(_ text: String, for item: ClipItem) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store, var current = self.item(with: item.id) else { return }
        let rtf = current.rtfFile
        current.rtfFile = nil
        current.kind = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? .link : .text
        current.text = trimmed
        current.byteCount = trimmed.utf8.count
        current.date = Date()
        changeHistory {
            try store.update(current)
            recentItems.removeAll { $0.id == current.id }
            return [.init(image: nil, rtf: rtf)]
        }
    }

    func item(with id: UUID) -> ClipItem? {
        if let recent = recentItems.first(where: { $0.id == id }) { return recent }
        do { return try store?.item(id: id) }
        catch { reportStorageError(); return nil }
    }

    func reveal(_ item: ClipItem) {
        guard let item = self.item(with: item.id) else { return }
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
        // Ignoring an app is forward-only; it does not implicitly delete history.
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

    /// List thumbnails never hold the full-size image in the cache.
    func thumbnail(for item: ClipItem) async -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        let key = url.lastPathComponent as NSString
        if let image = thumbCache.object(forKey: key) { return image }
        let bitmap = await readInBackground(on: thumbnailReads) { Self.decodeThumbnail(at: url) }
        guard !Task.isCancelled, let bitmap else { return nil }
        if let image = thumbCache.object(forKey: key) { return image }
        let image = NSImage(cgImage: bitmap, size: .zero)
        thumbCache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }

    nonisolated private static func decodeThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary)
    }

    private func removeFiles(_ attachment: ClipboardHistoryStore.Attachment) {
        if let file = attachment.image, (file as NSString).lastPathComponent == file, !file.isEmpty {
            thumbCache.removeObject(forKey: file as NSString)
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(file))
        }
        if let file = attachment.rtf, (file as NSString).lastPathComponent == file, !file.isEmpty {
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
        defaults.set(anchorAtCaret, forKey: "clipboard.anchorAtCaret")
    }

    private func refreshHistory(_ db: ClipboardHistoryStore) throws {
        let stats = try db.stats()
        recentItems = try db.recent(keeping: recentItems)
        historyCount = stats.count
        pinnedCount = stats.pinned
        byteTotal = stats.bytes
        historyRevision &+= 1
    }

    @discardableResult
    private func changeHistory(_ change: () throws -> [ClipboardHistoryStore.Attachment]) -> Bool {
        guard let store else { return false }
        do {
            let removed = try change()
            for attachment in removed { removeFiles(attachment) }
            try refreshHistory(store)
            return true
        } catch {
            reportStorageError()
            return false
        }
    }

    private func reportStorageError() {
        if !storageFailed { storageFailed = true }
        Debug.log("clipboard: local history operation failed")
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
