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
        let range = CMTimeRange(start: .zero, duration: try await source.load(.duration))
        let inputVideo = try await videoTrack(in: source)
        let mainRange = try await inputVideo.load(.timeRange)
        let main = try add(inputVideo, to: asset, range: mainRange, at: mainRange.start)
        for audio in try await source.loadTracks(withMediaType: .audio) {
            let audioRange = CMTimeRangeGetIntersection(try await audio.load(.timeRange), otherRange: range)
            if audioRange.duration > .zero {
                _ = try add(audio, to: asset, range: audioRange, at: audioRange.start)
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
        if let url = appearance.backdrop {
            if let image = ScreenshotService.importImage(url) {
                still = CIImage(cgImage: image)
            } else {
                let video = AVURLAsset(url: url)
                let track = try await videoTrack(in: video)
                let trackRange = try await track.load(.timeRange)
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
        composition.instructions = [RecordingFinishInstruction(
            range: range, main: main.trackID, background: backdropID, mainTransform: sourceTransform,
            backgroundTransform: backdropTransform, layers: render, segments: segments, trace: trace)]
        return Preview(asset: asset, composition: composition)
    }

    private static func videoTrack(in asset: AVAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoBezelError.noVideoTrack
        }
        return track
    }

    private static func add(_ source: AVAssetTrack, to asset: AVMutableComposition, range: CMTimeRange,
                            at start: CMTime) throws -> AVMutableCompositionTrack {
        guard let track = asset.addMutableTrack(withMediaType: source.mediaType,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoBezelError.exportUnavailable
        }
        try track.insertTimeRange(range, of: source, at: start)
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

    init(range: CMTimeRange, main: CMPersistentTrackID, background: CMPersistentTrackID,
         mainTransform: CGAffineTransform, backgroundTransform: CGAffineTransform,
         layers: RecordingFinishLayers, segments: [ZoomSegment], trace: RecordingZoom) {
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
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? RecordingFinishInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: VideoBezelError.exportUnavailable)
                return
            }
            let screen = request.sourceFrame(byTrackID: instruction.main)
                .map { CIImage(cvPixelBuffer: $0).transformed(by: instruction.mainTransform) }
            let background = instruction.background == kCMPersistentTrackID_Invalid ? nil :
                request.sourceFrame(byTrackID: instruction.background)
                    .map { CIImage(cvPixelBuffer: $0).transformed(by: instruction.backgroundTransform) }
            let time = request.compositionTime.seconds
            let frame = instruction.layers.render(screen: screen, background: background, time: time,
                                                  segments: instruction.segments, trace: instruction.trace)
            context.render(frame, to: output, bounds: instruction.layers.canvas,
                           colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            request.finish(withComposedVideoFrame: output)
        }
    }
}
