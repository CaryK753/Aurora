import AVFoundation
import CoreImage
import ImageIO

enum RecordingFinish {
    struct Preview {
        let asset: AVAsset
        let composition: AVVideoComposition
    }

    static func make(movie: URL, segments: [ZoomSegment], trace: RecordingZoom,
                     appearance: RecordingAppearance, frame: DeviceFrame?) async throws -> Preview {
        if appearance.frameID != nil && frame == nil { throw VideoBezelError.frameUnavailable }
        let source = AVURLAsset(url: movie)
        guard appearance.needsRendering else {
            let composition = try await RecordingZoom.composition(for: source) { time, extent in
                ZoomSegment.crop(segments, trace: trace, at: time, extent: extent)
            }
            return Preview(asset: source, composition: composition)
        }

        let asset = AVMutableComposition()
        let duration = try await source.load(.duration)
        let map = RecordingEditMap(appearance, duration: duration.seconds)
        let ranges = map.spans.map { span in
            CMTimeRange(start: CMTime(seconds: span.lowerBound, preferredTimescale: 60_000),
                        end: span.upperBound == duration.seconds ? duration : CMTime(seconds: span.upperBound, preferredTimescale: 60_000))
        }
        guard !ranges.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let length = ranges.reduce(CMTime.zero) { $0 + $1.duration }
        let range = CMTimeRange(start: .zero, duration: length)
        let inputVideo = try await videoTrack(in: source)
        let main = try await add(inputVideo, to: asset, ranges: ranges)
        if appearance.mute != true {
            for audio in try await source.loadTracks(withMediaType: .audio) {
                _ = try await add(audio, to: asset, ranges: ranges)
            }
        }

        let sourceTransform = try await inputVideo.load(.preferredTransform)
        let sourceSize = CGRect(origin: .zero, size: try await inputVideo.load(.naturalSize)).applying(sourceTransform).standardized.size
        let decorated = appearance.hasBackdrop || frame != nil
        let scale = decorated ? min(1, 2560 / max(sourceSize.width, sourceSize.height)) : 1
        let canvas = CGRect(x: 0, y: 0, width: max(2, floor(sourceSize.width * scale / 2) * 2),
                            height: max(2, floor(sourceSize.height * scale / 2) * 2))
        var still: CIImage?
        var backdropID = CMPersistentTrackID(kCMPersistentTrackID_Invalid)
        var backdropTransform = CGAffineTransform.identity
        let wallpaper = appearance.wallpaper
        let url = wallpaper.map { $0.url } ?? appearance.backdrop
        let animated = try RecordingAnimatedBackdrop(url: url, wallpaper: wallpaper, canvas: canvas.size)
        if animated == nil, let url {
            if WallpaperKind(url: url) != .video, let image = ScreenshotService.importImage(url) {
                still = CIImage(cgImage: image)
            } else {
                let video = AVURLAsset(url: url)
                let track = try await videoTrack(in: video)
                var trackRange = try await track.load(.timeRange)
                if let wallpaper, wallpaper.trimStart > 0 || wallpaper.trimEnd > 0 {
                    let from = CMTime(seconds: max(0, wallpaper.trimStart), preferredTimescale: 60000)
                    let to = wallpaper.trimEnd > 0 ? CMTime(seconds: wallpaper.trimEnd, preferredTimescale: 60000) : trackRange.end
                    trackRange = CMTimeRangeGetIntersection(trackRange, otherRange: CMTimeRange(start: from, end: to))
                }
                backdropTransform = try await track.load(.preferredTransform)
                guard trackRange.duration.seconds >= 1.0 / 30,
                      let loop = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw VideoBezelError.noVideoTrack
                }
                backdropID = loop.trackID
                var time = CMTime.zero
                while time < range.duration {
                    try Task.checkCancellation()
                    let length = CMTimeMinimum(trackRange.duration, range.duration - time)
                    try loop.insertTimeRange(CMTimeRange(start: trackRange.start, duration: length), of: track, at: time)
                    time = time + length
                }
            }
        }

        let render = try RecordingFinishLayers(canvas: canvas, frame: frame, appearance: appearance, still: still)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = RecordingFinishCompositor.self
        composition.renderSize = canvas.size
        let fps = try await inputVideo.load(.nominalFrameRate)
        composition.frameDuration = CMTime(seconds: fps > 0 ? 1 / Double(fps) : 1 / 30, preferredTimescale: 60_000)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        var at = CMTime.zero
        composition.instructions = ranges.map { sourceRange in
            let outputRange = CMTimeRange(start: at, duration: sourceRange.duration)
            let offset = (sourceRange.start - at).seconds
            at = at + sourceRange.duration
            return RecordingFinishInstruction(range: outputRange, main: main.trackID, background: backdropID,
                mainTransform: sourceTransform, backgroundTransform: backdropTransform, layers: render,
                segments: segments, trace: trace, offset: offset, animated: animated)
        }
        return Preview(asset: asset, composition: composition)
    }

    private static func videoTrack(in asset: AVAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoBezelError.noVideoTrack
        }
        return track
    }

    private static func add(_ source: AVAssetTrack, to asset: AVMutableComposition, ranges: [CMTimeRange]) async throws -> AVMutableCompositionTrack {
        guard let track = asset.addMutableTrack(withMediaType: source.mediaType,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoBezelError.exportUnavailable
        }
        let trackRange = try await source.load(.timeRange)
        var at = CMTime.zero
        for range in ranges {
            let overlap = CMTimeRangeGetIntersection(range, otherRange: trackRange)
            if overlap.duration > .zero {
                try track.insertTimeRange(overlap, of: source, at: at + (overlap.start - range.start))
            }
            at = at + range.duration
        }
        return track
    }
}

private final class RecordingFinishInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    var enablePostProcessing: Bool { false }
    var containsTweening: Bool { true }
    var requiredSourceTrackIDs: [NSValue]? {
        (background == kCMPersistentTrackID_Invalid ? [main] : [main, background]).map { NSNumber(value: $0) }
    }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }
    let main: CMPersistentTrackID
    let background: CMPersistentTrackID
    let mainTransform: CGAffineTransform
    let backgroundTransform: CGAffineTransform
    let layers: RecordingFinishLayers
    let segments: [ZoomSegment]
    let trace: RecordingZoom
    let offset: Double
    let animated: RecordingAnimatedBackdrop?

    init(range: CMTimeRange, main: CMPersistentTrackID, background: CMPersistentTrackID,
         mainTransform: CGAffineTransform, backgroundTransform: CGAffineTransform,
         layers: RecordingFinishLayers, segments: [ZoomSegment], trace: RecordingZoom, offset: Double, animated: RecordingAnimatedBackdrop?) {
        self.offset = offset
        self.animated = animated
        timeRange = range
        self.main = main
        self.background = background
        self.mainTransform = mainTransform
        self.backgroundTransform = backgroundTransform
        self.layers = layers
        self.segments = segments
        self.trace = trace
    }
}

final class RecordingFinishCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let format: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { format }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { format }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RecordingFinishInstruction else {
            request.finish(with: VideoBezelError.exportUnavailable)
            return
        }
        if let animated = instruction.animated {
            Task {
                do {
                    let image = try await animated.image(at: request.compositionTime.seconds)
                    render(request, instruction, backdrop: image)
                } catch { request.finish(with: error) }
            }
        } else { render(request, instruction, backdrop: nil) }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest, _ instruction: RecordingFinishInstruction, backdrop: CIImage?) {
        autoreleasepool {
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: VideoBezelError.exportUnavailable)
                return
            }
            let screen = request.sourceFrame(byTrackID: instruction.main)
                .map { CIImage(cvPixelBuffer: $0).transformed(by: instruction.mainTransform) }
            let background = instruction.background == kCMPersistentTrackID_Invalid ? nil :
                request.sourceFrame(byTrackID: instruction.background)
                    .map { CIImage(cvPixelBuffer: $0).transformed(by: instruction.backgroundTransform) }
            let time = request.compositionTime.seconds
            let frame = instruction.layers.render(screen: screen, background: backdrop ?? background, time: time + instruction.offset,
                                                  segments: instruction.segments, trace: instruction.trace)
            context.render(frame, to: output, bounds: instruction.layers.canvas,
                           colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            request.finish(withComposedVideoFrame: output)
        }
    }
}
