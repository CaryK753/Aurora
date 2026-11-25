import CoreImage
import ImageIO
import SwiftUI

/// 只缓存最近使用的小图。预览跳播和乱序导出按时间寻帧，不依赖桌面的动画时钟。
final class RecordingAnimatedBackdrop: @unchecked Sendable {
    private let source: CGImageSource?
    private let ends: [Double]
    private let scene: WallpaperItem?
    private let size: CGSize
    private let frames = NSCache<NSNumber, CGImage>()
    private let lock = NSLock()

    init?(url: URL?, wallpaper: WallpaperItem?, canvas: CGSize) throws {
        size = canvas.applying(.init(scaleX: min(1, 960 / max(canvas.width, canvas.height)),
                                     y: min(1, 960 / max(canvas.width, canvas.height))))
        frames.countLimit = 8
        scene = wallpaper?.kind == .procedural ? wallpaper : nil
        if scene != nil {
            source = nil
            ends = []
        } else if let url, url.pathExtension.lowercased() == "gif" {
            guard let file = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(file) > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            source = file
            var sum = 0.0
            ends = (0..<CGImageSourceGetCount(file)).map { i in
                let properties = CGImageSourceCopyPropertiesAtIndex(file, i, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                sum += delay >= 0.01 ? delay : 0.1
                return sum
            }
        } else { return nil }
    }

    func image(at time: Double) async throws -> CIImage {
        let image: CGImage?
        if let scene {
            let tick = Int(max(0, time * 20))
            image = await MainActor.run {
                if let frame = frames.object(forKey: NSNumber(value: tick)) { return frame }
                let view = ProceduralSceneFrame(style: scene.style ?? "aurora", hueShift: scene.hue ?? 0, time: Double(tick) / 20)
                    .frame(width: size.width, height: size.height)
                let frame = ImageRenderer(content: view).cgImage
                if let frame { frames.setObject(frame, forKey: NSNumber(value: tick)) }
                return frame
            }
        } else if let source, let duration = ends.last {
            let phase = max(0, time).truncatingRemainder(dividingBy: duration)
            var lo = 0, hi = ends.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ends[mid] <= phase { lo = mid + 1 } else { hi = mid }
            }
            let index = min(lo, ends.count - 1)
            image = lock.withLock {
                let key = NSNumber(value: index)
                if let frame = frames.object(forKey: key) { return frame }
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
                ] as CFDictionary) else { return nil }
                frames.setObject(frame, forKey: key)
                return frame
            }
        } else { image = nil }
        guard let image else { throw CocoaError(.fileReadCorruptFile) }
        return CIImage(cgImage: image)
    }
}
