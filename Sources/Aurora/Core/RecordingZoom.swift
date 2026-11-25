import AppKit
import AVFoundation
import CoreImage

struct ZoomPoint: Codable {
    let time: Double
    let x: Double
    let y: Double
    let click: Bool
    var hidden: Bool? = nil
}

/// 时间线可延长到任意时刻，保留录制范围内的位置变化。坐标以画面左下角为原点。
struct RecordingZoomTrace {
    var bounds: CGRect = .zero
    var visibleBounds: CGRect?
    var origin = CMTime.invalid
    var points: [ZoomPoint] = []
    mutating func sample(_ point: CGPoint, at mapped: CMTime, click: Bool) {
        guard !bounds.isEmpty, origin.isNumeric else { return }
        let t = (mapped - origin).seconds
        guard t >= 0, t >= (points.last?.time ?? 0) else { return }
        guard (visibleBounds ?? bounds).contains(point) else {
            if !click, let last = points.last, last.hidden != true {
                points.append(ZoomPoint(time: t, x: last.x, y: last.y, click: false, hidden: true))
            }
            return
        }
        let x = (point.x - bounds.minX) / bounds.width, y = (bounds.maxY - point.y) / bounds.height
        if !click, let last = points.last, last.hidden != true, last.x == x, last.y == y { return }
        points.append(ZoomPoint(time: t, x: x, y: y, click: click))
    }
}

/// 点击使用事件自身的位置，普通移动按固定频率采样供事后编辑。
@MainActor
final class RecordingZoomMonitor {
    private var monitors: [Any] = []
    private var timer: Timer?

    func start(enabled: Bool, sample: @escaping (CGPoint, Bool, CMTime) -> Void) {
        stop()
        guard enabled else { return }
        let clock = CMClockGetHostTimeClock()
        let handle: (NSEvent) -> Void = { event in
            guard let point = event.cgEvent?.location else { return }
            sample(point, true, CMClockGetTime(clock))
        }
        let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
            if let point = CGEvent(source: nil)?.location {
                sample(point, false, CMClockGetTime(clock))
            }
        }
        timer.tolerance = 0.015
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handle($0); return $0 }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
    }
}

struct RecordingPointerData: Codable {
    let points: [ZoomPoint]
    let embeddedCursor: Bool

    static func load(from movie: URL) throws -> Self {
        let url = RecordingZoom.metadata(movie)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self(points: [], embeddedCursor: true)
        }
        let decoder = JSONDecoder()
        if let current = try? decoder.decode(Self.self, from: data) { return current }
        return Self(points: try decoder.decode([ZoomPoint].self, from: data), embeddedCursor: true)
    }
}

struct RecordingZoom {
    let points: [ZoomPoint]
    let clicks: [ZoomPoint]

    init(points: [ZoomPoint]) {
        self.points = points
        clicks = points.filter(\.click)
    }

    static func metadata(_ movie: URL) -> URL {
        movie.deletingLastPathComponent().appendingPathComponent("." + movie.lastPathComponent + ".zoom.json")
    }

    private func upperBound(_ list: [ZoomPoint], _ time: Double) -> Int {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func ease(_ value: Double) -> Double {
        let x = max(0, min(1, value))
        return x * x * (3 - 2 * x)
    }

    func crop(at time: Double, extent: CGRect, magnification: Double) -> CGRect {
        let i = upperBound(clicks, time)
        guard i > 0 else { return extent }
        let age = time - clicks[i - 1].time
        guard age < 2 else { return extent }
        var strength = 0.0
        for index in (0..<i).reversed() {
            let elapsed = time - clicks[index].time
            if elapsed >= 2 { break }
            strength = max(strength, ease(elapsed / 0.35) * ease((2 - elapsed) / 0.55))
            if strength == 1 { break }
        }
        let scale = 1 + (magnification - 1) * strength
        return Self.crop(extent, scale: scale, center: center(at: time))
    }

    func center(at time: Double) -> CGPoint {
        guard let first = points.first else { return CGPoint(x: 0.5, y: 0.5) }
        let j = upperBound(points, time)
        guard j > 0 else { return CGPoint(x: first.x, y: first.y) }
        let p = points[j - 1]
        let next = points[min(j, points.count - 1)]
        let fraction = next.time > p.time && next.time - p.time < 0.4 && next.hidden != true && p.hidden != true ? ease((time - p.time) / (next.time - p.time)) : 0
        return CGPoint(x: p.x + (next.x - p.x) * fraction, y: p.y + (next.y - p.y) * fraction)
    }

    func recentClick(at time: Double, within duration: Double) -> ZoomPoint? {
        let index = upperBound(clicks, time)
        guard index > 0, time - clicks[index - 1].time < duration else { return nil }
        return clicks[index - 1]
    }

    func cursor(at time: Double) -> CGPoint? {
        let index = upperBound(points, time)
        guard index > 0, points[index - 1].hidden != true else { return nil }
        return center(at: time)
    }

    static func crop(_ extent: CGRect, scale: Double, center: CGPoint) -> CGRect {
        let w = extent.width / scale, h = extent.height / scale
        let x = extent.minX + extent.width * center.x
        let y = extent.minY + extent.height * center.y
        return CGRect(x: max(extent.minX, min(extent.maxX - w, x - w / 2)),
                      y: max(extent.minY, min(extent.maxY - h, y - h / 2)), width: w, height: h)
    }

    static func export(_ movie: URL, magnification: Double) async throws -> URL {
        let points = try RecordingPointerData.load(from: movie).points
        let zoom = RecordingZoom(points: points)
        guard !zoom.clicks.isEmpty, zip(points, points.dropFirst()).allSatisfy({ $0.time <= $1.time }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let asset = AVURLAsset(url: movie)
        let composition = try await composition(for: asset) { time, extent in
            zoom.crop(at: time, extent: extent, magnification: magnification)
        }
        return try await export(movie, asset: asset, composition: composition)
    }

    static func composition(for asset: AVAsset, crop: @escaping @Sendable (Double, CGRect) -> CGRect) async throws -> AVVideoComposition {
        let base = try await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let image = request.sourceImage
            let rect = crop(request.compositionTime.seconds, image.extent)
            let transformed = image.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
                .transformed(by: .init(scaleX: image.extent.width / rect.width, y: image.extent.height / rect.height))
            request.finish(with: transformed, context: nil)
        })
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first,
              CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) == nil,
              CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) == nil,
              CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) == nil,
              let fallback = base.mutableCopy() as? AVMutableVideoComposition else { return base }
        fallback.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        fallback.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        fallback.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return fallback
    }

    static func export(_ movie: URL, asset: AVAsset, composition: AVVideoComposition, finished: Bool = false) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.videoComposition = composition
        let output = movie.deletingPathExtension().appendingPathExtension((finished ? "edit-" : "zoom-") + UUID().uuidString.prefix(8) + ".mp4")
        do { try await session.export(to: output, as: .mp4) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        return output
    }
}
