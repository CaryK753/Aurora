//  ScreenshotService.swift
//  Aurora — 截图：区域捕获、长截图拼接、带壳合成
//
//  采集用 CGWindowListCreateImage（需要屏幕录制权限）；长截图是「滚动 + 逐屏
//  捕获 + 重叠行匹配拼接」；带壳用 Apple 官方 Product Bezels（PNG + 屏幕
//  矩形清单内置在 Resources/DeviceFrames），按截图比例与 Mac 型号自动推荐。

import AppKit
import CoreGraphics
import Combine
import ScreenCaptureKit
import ImageIO

// MARK: - 设备外壳

struct DeviceFrame: Identifiable, Equatable {
    let id: String          // 文件名去扩展名
    let device: String      // 显示名
    let category: String    // mac / iphone
    let pixelWidth: Int
    let pixelHeight: Int
    /// 屏幕孔洞（帧图坐标，top-left origin）
    let screen: CGRect

    var aspect: CGFloat { CGFloat(pixelWidth) / CGFloat(pixelHeight) }
    var screenAspect: CGFloat { screen.width / screen.height }

    /// 同一尺寸下的配色 / 方向标签（"MacBook Pro 14″ 深空黑" → "深空黑"）
    var variantLabel: String {
        device.split(separator: " ").last.map(String.init) ?? device
    }
}

// MARK: - 服务

@MainActor
final class ScreenshotService: ObservableObject {
    static let shared = ScreenshotService()

    // MARK: 外壳库

    @Published private(set) var frames: [DeviceFrame] = []
    /// 用户指定的默认外壳；nil 表示跟着本机自动识别
    @Published var preferredFrameID: String? {
        didSet {
            if let preferredFrameID {
                UserDefaults.standard.set(preferredFrameID, forKey: "screenshot.preferredFrame")
            } else {
                UserDefaults.standard.removeObject(forKey: "screenshot.preferredFrame")
            }
        }
    }

    private init() {
        loadFrames()
        preferredFrameID = UserDefaults.standard.string(forKey: "screenshot.preferredFrame")
            .flatMap { id in frames.contains { $0.id == id } ? id : nil }
    }

    /// 按主屏物理像素挑机型（14 / 16 英寸）
    ///
    /// 注意：系统不暴露机身配色（ioreg / system_profiler 里都没有），
    /// 所以同一尺寸的「深空黑 / 银色」只能由用户自己指定，这里不猜。
    var autoFrame: DeviceFrame? {
        guard !frames.isEmpty else { return nil }
        let macs = frames.filter { $0.category == "mac" }
        guard !macs.isEmpty else { return frames.first }
        // 认的是「内建屏」：外接显示器当主屏时，默认外壳仍该是这台 MacBook
        let screen = Self.builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
        let pixelWidth = screen.map { CGFloat($0.frame.width * $0.backingScaleFactor) }
            ?? CGFloat(Self.mainDisplayPixelWidth())
        let aspect = screen.map { $0.frame.width / $0.frame.height } ?? 16.0 / 10.0
        // 宽度按机型分辨率匹配，比例用来区分内建屏（16:10）与外接屏（16:9）
        func score(_ frame: DeviceFrame) -> CGFloat {
            abs(frame.screen.width - pixelWidth) / 1200 + abs(frame.screenAspect - aspect) * 12
        }
        return macs.min { score($0) < score($1) }
    }

    /// 带内建屏（笔记本 / iMac）的那块 NSScreen
    nonisolated static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    /// 界面与编辑器都认这一款：用户指定优先，否则自动识别
    var defaultFrame: DeviceFrame? {
        if let preferredFrameID, let frame = frames.first(where: { $0.id == preferredFrameID }) {
            return frame
        }
        return autoFrame
    }

    var isDefaultAuto: Bool { preferredFrameID == nil }

    /// 和默认款同尺寸的其它款式（同机型不同配色 / 方向）——给「换配色」用
    var defaultFrameVariants: [DeviceFrame] {
        guard let base = defaultFrame else { return [] }
        return frames.filter {
            $0.category == base.category
                && $0.pixelWidth == base.pixelWidth
                && $0.screen.size == base.screen.size
        }
    }

    /// 除默认款以外的外壳（界面里折叠展示）
    var others: [DeviceFrame] {
        guard let id = defaultFrame?.id else { return frames }
        return frames.filter { $0.id != id }
    }

    /// 资源没加载出来时补一次（预览/调试会先建视图再读资源）
    func reloadIfNeeded() {
        if frames.isEmpty { loadFrames() }
    }

    private func loadFrames() {
        guard let manifestURL = Self.resourceURL("frames.json"),
              let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Debug.log("device frames manifest missing")
            return
        }
        frames = list.compactMap { entry in
            guard let file = entry["file"] as? String,
                  let w = entry["w"] as? Int,
                  let h = entry["h"] as? Int,
                  let rect = entry["screen"] as? [Int], rect.count == 4 else { return nil }
            let id = (file as NSString).deletingPathExtension
            guard Self.resourceURL(file) != nil else { return nil }
            return DeviceFrame(
                id: id,
                device: entry["device"] as? String ?? id,
                category: entry["category"] as? String ?? "mac",
                pixelWidth: w,
                pixelHeight: h,
                screen: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
            )
        }
        Debug.log("device frames: \(frames.count) 款（清单 \(list.count) 项）")
    }

    /// 主 bundle 里的资源（开发期也兼容仓库 Resources 目录）
    nonisolated static let framesDirectoryName = "DeviceFrames"

    /// 外壳资源都在 Contents/Resources/DeviceFrames/ 下，而 Bundle 的资源查找**不会**递归到子目录，
    /// 必须显式带 subdirectory；否则只有开发机（仓库还在）能靠下面的路径兜底找到，装到别的机器上就是空的。
    nonisolated static func resourceURL(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: framesDirectoryName) {
            return url
        }
        // 有些打包工具会把资源平铺到 Resources 根目录
        if let url = Bundle.main.url(forResource: base, withExtension: ext) {
            return url
        }
        if let root = Bundle.main.resourceURL {
            let direct = root.appendingPathComponent("\(framesDirectoryName)/\(name)")
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        // swift run / 调试时的仓库路径兜底
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Core
            .deletingLastPathComponent()     // Aurora
            .deletingLastPathComponent()     // Sources
            .deletingLastPathComponent()     // 仓库根
            .appendingPathComponent("Resources/\(framesDirectoryName)/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - 设备识别

    /// sysctl hw.model，例如 MacBookPro18,3
    nonisolated static func macModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Mac 的友好名字（识别到哪个系列就够了）
    nonisolated static func macDeviceName() -> String {
        let model = macModelIdentifier()
        if model.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if model.hasPrefix("MacBookAir") { return "MacBook Air" }
        if model.hasPrefix("MacBook") { return "MacBook" }
        if model.hasPrefix("iMac") { return "iMac" }
        if model.hasPrefix("Macmini") { return "Mac mini" }
        if model.hasPrefix("MacStudio") { return "Mac Studio" }
        if model.hasPrefix("MacPro") { return "Mac Pro" }
        return "Mac"
    }

    /// 主屏物理像素宽（14/16 英寸 MacBook 靠它区分）
    nonisolated static func mainDisplayPixelWidth() -> Int {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        return Int(screen.frame.width * screen.backingScaleFactor)
    }

    /// 按截图自动推荐外壳：全屏 Mac 截图 → 本机对应款；iPhone 比例 → iPhone
    func suggestFrame(for imageSize: CGSize) -> DeviceFrame? {
        guard !frames.isEmpty else { return nil }
        let aspect = imageSize.width / imageSize.height

        // iPhone 竖屏（9:19.5 附近）
        if abs(aspect - 1206.0 / 2622.0) < 0.03,
           let frame = frames.first(where: { $0.category == "iphone" && $0.screen.width < $0.screen.height }) {
            return frame
        }
        // iPhone 横屏
        if abs(aspect - 2622.0 / 1206.0) < 0.03,
           let frame = frames.first(where: { $0.category == "iphone" && $0.screen.width > $0.screen.height }) {
            return frame
        }
        // Mac 全屏：优先用户指定的默认款，其次按比例 + 分辨率挑（外接屏别套进笔记本壳）
        if let preferred = defaultFrame, preferred.category == "mac" { return preferred }
        let pixelWidth = CGFloat(Self.mainDisplayPixelWidth())
        let candidates = frames.filter { $0.category == "mac" }
        func score(_ frame: DeviceFrame) -> CGFloat {
            abs(frame.screenAspect - aspect) * 10 + abs(frame.screen.width - pixelWidth) / 1500
        }
        if let exact = candidates.min(by: { score($0) < score($1) }) {
            return exact
        }
        return frames.first
    }

    // MARK: - 采集

    /// 是否拿得到屏幕内容
    nonisolated static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    nonisolated static func requestScreenCapturePermission() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: 可选窗口（截图时点窗口直接截取整个 App 窗口）

    struct SelectableWindow: Identifiable, Equatable {
        let id: CGWindowID
        /// 全局坐标（左上原点，与 ScreenCaptureKit 一致）
        let frame: CGRect
        let title: String
        let appName: String

        var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
    }

    /// 屏幕上的可选窗口（排除自己、过小窗口与非普通层）
    nonisolated static func selectableWindows() async -> [SelectableWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        let ownBundle = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window in
            guard window.windowLayer == 0,
                  let app = window.owningApplication,
                  app.bundleIdentifier != ownBundle,
                  window.frame.width >= 120, window.frame.height >= 80 else { return nil }
            return SelectableWindow(
                id: window.windowID,
                frame: window.frame,
                title: window.title ?? "",
                appName: app.applicationName
            )
        }
    }

    /// 捕获屏幕的一个矩形（全局 NS 坐标）。
    /// macOS 15 起 CGWindowListCreateImage 被移除，这里走 ScreenCaptureKit 单帧截图。
    nonisolated static func capture(rect: CGRect) async -> CGImage? {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        // NS（左下原点）→ CG（左上原点，全屏桌面空间）
        let cgRect = CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        // 找覆盖该矩形的显示器；跨屏时取面积最大的那块
        let display = content.displays
            .filter { $0.frame.intersects(cgRect) }
            .max { $0.frame.intersection(cgRect).width * $0.frame.intersection(cgRect).height
                    < $1.frame.intersection(cgRect).width * $1.frame.intersection(cgRect).height }
            ?? content.displays.first
        guard let display else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // sourceRect 是显示器内坐标（点）
        config.sourceRect = CGRect(
            x: cgRect.origin.x - display.frame.origin.x,
            y: cgRect.origin.y - display.frame.origin.y,
            width: cgRect.width,
            height: cgRect.height
        )
        let scale: CGFloat = NSScreen.screens.first { $0.frame == display.frame }?.backingScaleFactor ?? 2
        config.width = max(2, Int(cgRect.width * scale))
        config.height = max(2, Int(cgRect.height * scale))
        config.captureResolution = .best
        config.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - 长截图拼接

    struct StitchResult {
        let image: CGImage
        let segments: Int
        let droppedTail: Int   // 因对不上被丢掉的最后一屏像素（滚动过头时）
    }

    /// 把逐屏捕获的图拼成一张长图：相邻两屏按重叠行匹配对齐
    nonisolated static func stitch(_ images: [CGImage]) -> StitchResult? {
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return StitchResult(image: first, segments: 1, droppedTail: 0) }

        let width = first.width
        var canvas: CGImage = first

        for next in images.dropFirst() {
            // 宽度不一致（跨屏捕获）时放弃拼接这一段
            guard next.width == width else { continue }
            guard let merged = merge(canvas: canvas, segment: next) else { continue }
            canvas = merged
        }
        return StitchResult(image: canvas, segments: images.count, droppedTail: 0)
    }

    /// 两段拼接：在 segment 顶部找与 canvas 底部匹配的重叠行数
    private nonisolated static func merge(canvas: CGImage, segment: CGImage) -> CGImage? {
        let canvasBM = bitmap(of: canvas)
        let segmentBM = bitmap(of: segment)
        guard canvasBM != nil, segmentBM != nil else { return nil }

        let width = canvas.width
        let maxOverlap = min(canvas.height, segment.height) - 8
        guard maxOverlap > 8 else { return nil }

        var bestOffset = -1
        var bestScore = CGFloat.greatestFiniteMagnitude
        // 从小到大找重叠量；误差明显小于当前最优时才更新，偏好小位移（滚动增量）
        for overlap in stride(from: 8, through: maxOverlap, by: 2) {
            let score = diffScore(
                canvas: canvasBM!, segment: segmentBM!,
                canvasRow: canvas.height - overlap,
                segmentRow: 0,
                rows: min(overlap, 160),
                width: width
            )
            if score < bestScore * 0.98 {
                bestScore = score
                bestOffset = overlap
            }
        }
        guard bestOffset > 0 else { return nil }

        // 新内容 = canvas + segment[bestOffset...]
        let appendRows = segment.height - bestOffset
        guard appendRows > 0 else { return canvas }
        let totalHeight = canvas.height + appendRows

        guard let context = CGContext(
            data: nil, width: width, height: totalHeight, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(canvas, in: CGRect(x: 0, y: CGFloat(appendRows), width: CGFloat(width), height: CGFloat(canvas.height)))
        // segment 裁掉重叠部分后画在顶部（CG 坐标 y=0 在底部）
        if let cropped = segment.cropping(to: CGRect(x: 0, y: bestOffset, width: width, height: appendRows)) {
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(appendRows)))
        }
        return context.makeImage()
    }

    private nonisolated static func bitmap(of image: CGImage) -> [UInt8]? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let pointer = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
    }

    /// 两个位图带的平均差（抽列采样，够准也够快）
    private nonisolated static func diffScore(
        canvas: [UInt8], segment: [UInt8],
        canvasRow: Int, segmentRow: Int, rows: Int, width: Int
    ) -> CGFloat {
        var total: UInt64 = 0
        var samples: UInt64 = 0
        for row in stride(from: 0, to: rows, by: max(1, rows / 24)) {
            let cy = canvasRow + row, sy = segmentRow + row
            for x in stride(from: 0, to: width, by: 6) {
                let ci = (cy * width + x) * 4
                let si = (sy * width + x) * 4
                let d = abs(Int(canvas[ci]) - Int(segment[si]))
                    + abs(Int(canvas[ci + 1]) - Int(segment[si + 1]))
                    + abs(Int(canvas[ci + 2]) - Int(segment[si + 2]))
                total += UInt64(d)
                samples += 1
            }
        }
        guard samples > 0 else { return .greatestFiniteMagnitude }
        return CGFloat(total) / CGFloat(samples)
    }

    // MARK: - 带壳合成

    /// 把截图塞进外壳屏幕孔洞：截图等比 fit 进孔洞（居中），外壳盖上。
    /// 全程 CoreGraphics、像素尺寸精确（避免 NSImage lockFocus 被 2x 缩放搞糊）。
    nonisolated static func compose(image: CGImage, frame: DeviceFrame) -> CGImage? {
        guard let frameURL = resourceURL(frame.id + ".png"),
              let frameProvider = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
              let frameImage = CGImageSourceCreateImageAtIndex(frameProvider, 0, nil) else { return nil }

        let width = frame.pixelWidth
        let height = frame.pixelHeight
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let screen = frame.screen
        // CG 坐标是底部原点：把清单里的 top-left 矩形翻过来
        let screenCG = CGRect(
            x: screen.minX,
            y: CGFloat(height) - screen.maxY,
            width: screen.width,
            height: screen.height
        )

        // 屏幕垫黑底，比例差的部分不至于透出白底
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(screenCG)

        // 等比 fit 居中
        let scale = max(screen.width / CGFloat(image.width), screen.height / CGFloat(image.height))
        let drawW = CGFloat(image.width) * scale
        let drawH = CGFloat(image.height) * scale
        let drawRect = CGRect(
            x: screenCG.midX - drawW / 2,
            y: screenCG.midY - drawH / 2,
            width: drawW,
            height: drawH
        )
        context.saveGState()
        context.clip(to: screenCG)
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        context.restoreGState()

        // 外壳盖上（孔洞是透明的）
        context.interpolationQuality = .high
        context.draw(frameImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }
}

// MARK: - 像素写回（编辑器导出用）

extension CGImage {
    /// 转 NSBitmapImageRep（PNG 导出）
    func bitmapRep() -> NSBitmapImageRep? {
        NSBitmapImageRep(cgImage: self)
    }
}
