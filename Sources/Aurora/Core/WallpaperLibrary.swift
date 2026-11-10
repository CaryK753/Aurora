//  WallpaperLibrary.swift
//  Aurora — 壁纸库：导入 / 去重 / 缩略图 / Apple 自带壁纸索引

import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published private(set) var systemItems: [WallpaperItem] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var isImporting = false

    /// Apple 壁纸里被手动移除的条目（只影响列表，不动系统文件）
    @Published private(set) var hiddenSystemIDs: Set<String>
    /// 给「随机轮播」用的文件夹源
    @Published private(set) var randomFolders: [String]

    private var inFlight: Set<String> = []
    private let defaults = UserDefaults.standard

    private static let hiddenKey = "wallpaper.hiddenSystem"
    private static let foldersKey = "wallpaper.randomFolders"
    private static let indexKey = "wallpaper.index"

    // MARK: 目录

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Aurora", isDirectory: true)
    }

    nonisolated static var mediaDirectory: URL {
        supportDirectory.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    nonisolated static var thumbnailDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return base.appendingPathComponent("Aurora/WallpaperThumbs", isDirectory: true)
    }

    nonisolated static func ensureDirectories() {
        for directory in [mediaDirectory, thumbnailDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 内置的程序生成动态场景（每次启动补齐，用户移除后重启会回来）
    static let proceduralPresets: [WallpaperItem] = [
        ("proc-aurora", "aurora"), ("proc-waves", "waves"),
        ("proc-mesh", "mesh"), ("proc-sunset", "sunset")
    ].map { id, style in
        WallpaperItem(
            id: id, name: ProceduralWallpaper.displayName(for: style), path: "",
            kind: .procedural, bytes: 0, addedAt: Date(timeIntervalSince1970: 0), style: style
        )
    }

    init(scanSystem: Bool = true) {
        hiddenSystemIDs = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        randomFolders = defaults.stringArray(forKey: Self.foldersKey) ?? []
        loadIndex()
        let missing = Self.proceduralPresets.filter { preset in !items.contains { $0.id == preset.id } }
        if !missing.isEmpty {
            items = missing + items
            persistIndex()
        }
        if scanSystem { scanSystemWallpapers() }
    }

    // MARK: - 索引持久化

    private func loadIndex() {
        guard let data = defaults.data(forKey: Self.indexKey),
              let decoded = try? JSONDecoder().decode([WallpaperItem].self, from: data) else { return }
        items = decoded.filter { $0.fileExists || $0.kind == .procedural }
        if items.count != decoded.count { persistIndex() }
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.indexKey)
    }

    // MARK: - 查询

    func item(id: String) -> WallpaperItem? {
        items.first { $0.id == id } ?? systemItems.first { $0.id == id }
    }

    func items(kind: WallpaperKind?) -> [WallpaperItem] {
        guard let kind else { return items }
        return items.filter { $0.kind == kind }
    }

    var motionCount: Int { items.filter(\.kind.isMotion).count }
    var stillCount: Int { items.count - motionCount }
    /// Apple 库里的动态视频数量（航拍视频扫描到才有）
    var systemMotionCount: Int { systemItems.filter { $0.kind.isMotion }.count }

    // MARK: - 导入

    struct ImportResult {
        var added = 0
        var skipped = 0
        var message: String { added > 0 ? TF("已导入 %d 张壁纸", added) : T("没有新的壁纸可导入") }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> ImportResult {
        var result = ImportResult()
        Self.ensureDirectories()
        isImporting = true
        defer { isImporting = false }

        for url in urls {
            for file in Self.expand(url) {
                if addOne(file) { result.added += 1 } else { result.skipped += 1 }
            }
        }
        if result.added > 0 { persistIndex() }
        return result
    }

    /// 文件夹（含拖入的目录）递归展开，限制深度避免扫到巨大的目录树
    nonisolated static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }

        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let child = enumerator?.nextObject() as? URL {
            if enumerator!.level > 3 { enumerator?.skipDescendants() }
            if WallpaperKind(url: child) != nil { files.append(child) }
            if files.count >= 200 { break }
        }
        return files
    }

    private func addOne(_ source: URL) -> Bool {
        guard let kind = WallpaperKind(url: source) else { return false }
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = source.deletingPathExtension().lastPathComponent

        // 同一个文件已经导入过就跳过
        if items.contains(where: { $0.name == name && $0.bytes == bytes }) { return false }

        let destination = Self.mediaDirectory.appendingPathComponent(uniqueFileName(source.lastPathComponent))
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            Debug.log("wallpaper import failed: \(error.localizedDescription)")
            return false
        }

        let item = WallpaperItem(
            id: UUID().uuidString,
            name: name,
            path: destination.path,
            kind: kind,
            bytes: bytes,
            addedAt: Date()
        )
        items.append(item)
        return true
    }

    private func uniqueFileName(_ name: String) -> String {
        var candidate = name
        var index = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: Self.mediaDirectory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            index += 1
        }
        return candidate
    }

    func remove(_ item: WallpaperItem) {
        if !item.isSystem {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        persistIndex()
    }

    func rename(_ item: WallpaperItem, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[index].name = trimmed
        persistIndex()
    }

    /// 视频掐头去尾：写入条目并清掉旧缩略图
    func setTrim(_ item: WallpaperItem, start: Double, end: Double) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].trimStart = max(0, start)
        items[index].trimEnd = max(0, end)
        thumbnails[item.id] = nil
        requestThumbnail(items[index])
        persistIndex()
    }

    /// 程序生成场景：保存自定义配色
    @discardableResult
    func setHue(_ item: WallpaperItem, hue: Double?) -> WallpaperItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        items[index].hue = hue
        persistIndex()
        return items[index]
    }

    /// 把 Apple 自带的壁纸复制进自己的库，之后就能随意改片段 / 参与轮播
    @discardableResult
    func adopt(_ item: WallpaperItem) -> WallpaperItem? {
        guard item.isSystem else { return item }
        if addOne(item.url) {
            persistIndex()
            return items.last
        }
        return items.first { $0.name == item.name }
    }

    // MARK: - Apple 壁纸

    func scanSystemWallpapers() {
        let roots = [
            "/System/Library/Desktop Pictures",
            "/Library/Desktop Pictures",
            "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture",
            // Sonoma 起的航拍动态壁纸（用户在系统设置里选过屏保后才会缓存在这里）
            "/Library/Application Support/com.apple.idleassetsd",
            NSHomeDirectory() + "/Library/Application Support/com.apple.idleassetsd"
        ]
        var found: [WallpaperItem] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { continue }
            let rootURL = URL(fileURLWithPath: root, isDirectory: isDirectory.boolValue)
            if !isDirectory.boolValue {
                if let item = Self.systemItem(for: rootURL) { found.append(item) }
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let child = enumerator?.nextObject() as? URL {
                if enumerator!.level > 4 { enumerator?.skipDescendants() }
                if let item = Self.systemItem(for: child) { found.append(item) }
                if found.count > 300 { break }
            }
        }

        var seen = Set<String>()
        systemItems = found
            .filter { seen.insert($0.path).inserted }
            .filter { !hiddenSystemIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func systemItem(for url: URL) -> WallpaperItem? {
        guard let kind = WallpaperKind(url: url) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // 太小的图标 / 预览图不进列表
        guard bytes > 200_000 || kind.isMotion else { return nil }
        let rawName = url.deletingPathExtension().lastPathComponent
        return WallpaperItem(
            id: "apple:" + url.path,
            name: kind.isMotion ? cleanVideoName(rawName) : rawName,
            path: url.path,
            kind: kind,
            bytes: bytes,
            addedAt: Date.distantPast,
            isSystem: true
        )
    }

    /// 航拍视频文件名像 `0215_TR_City_4K` / `CC__Waves_4K`，整理成能看的名字
    nonisolated static func cleanVideoName(_ raw: String) -> String {
        let tokens = raw
            .replacingOccurrences(of: "__", with: "_")
            .split(separator: "_")
            .filter { token in
                // 去掉纯数字编号和两位大写地区码这类前缀
                if token.allSatisfy(\.isNumber) { return false }
                if token.count == 2, token.allSatisfy(\.isUppercase) { return false }
                return true
            }
        let cleaned = String(tokens.joined(separator: " "))
        return cleaned.isEmpty ? raw : cleaned
    }

    func hideSystem(_ item: WallpaperItem) {
        hiddenSystemIDs.insert(item.id)
        systemItems.removeAll { $0.id == item.id }
        defaults.set(Array(hiddenSystemIDs), forKey: Self.hiddenKey)
    }

    func restoreSystemWallpapers() {
        hiddenSystemIDs.removeAll()
        defaults.set([String](), forKey: Self.hiddenKey)
        scanSystemWallpapers()
    }

    // MARK: - 随机源文件夹

    func addRandomFolder(_ url: URL) {
        guard !randomFolders.contains(url.path) else { return }
        randomFolders.append(url.path)
        defaults.set(randomFolders, forKey: Self.foldersKey)
    }

    func removeRandomFolder(_ path: String) {
        randomFolders.removeAll { $0 == path }
        defaults.set(randomFolders, forKey: Self.foldersKey)
    }

    /// 把文件夹里的媒体文件读成条目（不复制，直接引用）
    nonisolated static func scanFolder(_ path: String, limit: Int = 300) -> [WallpaperItem] {
        var results: [WallpaperItem] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let child = enumerator?.nextObject() as? URL {
            if enumerator!.level > 3 { enumerator?.skipDescendants() }
            guard let kind = WallpaperKind(url: child) else { continue }
            let bytes = (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            results.append(
                WallpaperItem(
                    id: "file:" + child.path,
                    name: child.deletingPathExtension().lastPathComponent,
                    path: child.path,
                    kind: kind,
                    bytes: bytes,
                    addedAt: Date.distantPast,
                    isSystem: true
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    // MARK: - 缩略图（全部在后台线程用 CoreGraphics 生成，不碰 AppKit 绘图）

    func requestThumbnail(_ item: WallpaperItem, width: CGFloat = 360) {
        if thumbnails[item.id] != nil || inFlight.contains(item.id) { return }
        inFlight.insert(item.id)
        let trim = item.kind == .video ? item.trimStart : 0
        Task.detached(priority: .utility) {
            let image = Self.renderThumbnail(item: item, trim: trim, width: width)
            await MainActor.run {
                self.inFlight.remove(item.id)
                if let image { self.thumbnails[item.id] = image }
            }
        }
    }

    nonisolated static func renderThumbnail(item: WallpaperItem, trim: Double, width: CGFloat) -> NSImage? {
        ensureDirectories()
        let cache = thumbnailDirectory.appendingPathComponent("\(stableHash(item.id + "\(Int(trim * 10))"))-\(Int(width)).jpg")
        if let cached = NSImage(contentsOf: cache) { return cached }

        let source: CGImage?
        switch item.kind {
        case .image, .gif:
            source = imageFile(url: item.url, maxPixel: Int(width * 2))
        case .video:
            source = videoFrame(url: item.url, seconds: trim)
        case .procedural:
            return nil
        }
        guard let source else { return nil }

        let pixelWidth = Int(width)
        let pixelHeight = max(1, Int(width * 9 / 16))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let imageWidth = CGFloat(source.width)
        let imageHeight = CGFloat(source.height)
        let scale = max(CGFloat(pixelWidth) / max(imageWidth, 1), CGFloat(pixelHeight) / max(imageHeight, 1))
        let drawWidth = imageWidth * scale
        let drawHeight = imageHeight * scale
        context.draw(
            source,
            in: CGRect(
                x: (CGFloat(pixelWidth) - drawWidth) / 2,
                y: (CGFloat(pixelHeight) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
        )
        guard let output = context.makeImage() else { return nil }

        if let destination = CGImageDestinationCreateWithURL(cache as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }

    nonisolated static func imageFile(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func videoFrame(url: URL, seconds: Double) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let time = CMTime(seconds: max(0, seconds + 0.15), preferredTimescale: 600)
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }

    nonisolated static func videoDuration(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        return duration.isFinite ? duration : 0
    }

    nonisolated private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
