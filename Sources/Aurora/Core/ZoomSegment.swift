import Foundation

struct ZoomSegment: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var center: CGPoint
    var scale = 2.0
    var follows = true

    /// SC 的 contentRect 以点计，screenRect 是全局窗口范围。反推出整个视频对应的桌面范围。
    static func virtualFrame(screen: CGRect, content: CGRect, pixelScale: CGFloat, output: CGSize) -> CGRect {
        let xRatio = screen.width / (content.width * pixelScale)
        let yRatio = screen.height / (content.height * pixelScale)
        return CGRect(x: screen.minX - content.minX * pixelScale * xRatio,
                      y: screen.minY - content.minY * pixelScale * yRatio,
                      width: output.width * xRatio, height: output.height * yRatio)
    }

    static func automatic(_ trace: RecordingZoom, duration: Double) -> [Self] {
        var segments: [Self] = []
        for click in trace.clicks where click.time >= 0 && click.time < duration {
            let end = min(duration, click.time + 2)
            if let last = segments.indices.last, segments[last].end >= click.time {
                segments[last].end = end
            } else {
                segments.append(Self(start: click.time, end: end, center: CGPoint(x: click.x, y: click.y)))
            }
        }
        return segments
    }

    static func crop(_ segments: [Self], trace: RecordingZoom, at time: Double, extent: CGRect) -> CGRect {
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return extent }
        let s = segments[low - 1]
        guard time < s.end else { return extent }
        let span = s.end - s.start
        let t = min(1, (time - s.start) / min(0.35, span / 2), (s.end - time) / min(0.55, span / 2))
        return RecordingZoom.crop(extent, scale: 1 + (s.scale - 1) * t * t * (3 - 2 * t),
                                  center: s.follows ? trace.center(at: time) : s.center)
    }
}
