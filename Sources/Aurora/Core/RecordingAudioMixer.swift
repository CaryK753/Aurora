import AVFoundation

/// 将录屏的多个音源混为一条音轨，视频保持原编码。作者：wwj。
enum RecordingAudioMixer {
    static func mixIfNeeded(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count > 1 else { return }
        let directory = url.deletingLastPathComponent()
        let audioURL = directory.appendingPathComponent(".aurora-audio-\(UUID().uuidString).m4a")
        let movieURL = directory.appendingPathComponent(".aurora-mix-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: movieURL)
        }
        try await mixAudio(asset: asset, tracks: tracks, to: audioURL)
        let composition = AVMutableComposition()
        for source in try await asset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw failure() }
            let range = try await source.load(.timeRange)
            try target.insertTimeRange(range, of: source, at: range.start)
            target.preferredTransform = try await source.load(.preferredTransform)
        }
        let mixed = AVURLAsset(url: audioURL)
        guard let source = try await mixed.loadTracks(withMediaType: .audio).first,
              let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw failure() }
        let range = try await source.load(.timeRange)
        try target.insertTimeRange(range, of: source, at: range.start)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw failure() }
        try await export.export(to: movieURL, as: .mp4)
        guard try await AVURLAsset(url: movieURL).loadTracks(withMediaType: .audio).count == 1 else { throw failure() }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: movieURL)
    }

    private static func mixAudio(asset: AVAsset, tracks: [AVAssetTrack], to url: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        output.audioMix = mix
        guard reader.canAdd(output) else { throw failure() }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000
        ])
        guard writer.canAdd(input) else { throw failure() }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? failure() }
        writer.startSession(atSourceTime: .zero)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "aurora.recording.audio.mix")
            var ended = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !ended else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        ended = true
                        input.markAsFinished()
                        if reader.status == .failed || reader.status == .cancelled {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? failure())
                        } else {
                            writer.finishWriting {
                                if writer.status == .completed { continuation.resume() }
                                else { continuation.resume(throwing: writer.error ?? failure()) }
                            }
                        }
                        return
                    }
                    if !input.append(buffer) {
                        ended = true
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: writer.error ?? failure())
                        return
                    }
                }
            }
        }
    }

    private static func failure() -> Error {
        NSError(domain: "Aurora.RecordingAudioMixer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Recording audio could not be mixed"])
    }
}
