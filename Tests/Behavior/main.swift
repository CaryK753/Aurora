import AppKit
import AVFoundation
import QuartzCore
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

func T(_ value: String) -> String { value }
func TF(_ value: String, _ args: CVarArg...) -> String { String(format: value, arguments: args) }
enum Debug { static func log(_ value: String) {} }
// 只替代本测试不涉及的程序场景和真实 DDC 传输，不启动桌面窗口或写硬件。
struct ProceduralWallpaperView: View {
    let style: String
    let hueShift: Double
    var body: some View { Color.clear }
}

/// 桌面层的程序化场景时钟不在本测试范围内，只留渲染器需要的接口
@MainActor
final class ProceduralClock {
    static let shared = ProceduralClock()
    func setPlaying(_ playing: Bool, token: String) {}
    func forget(token: String) {}
}
final class DDCChannel {
    let succeeds: Bool
    init(_ succeeds: Bool) { self.succeeds = succeeds }
    func write(_ code: UInt8, value: UInt16) -> Bool { succeeds }
}

func check(_ title: String, _ condition: @autoclosure () -> Bool) {
    precondition(condition(), title)
    print("✓ \(title)")
}

func pump(until condition: () -> Bool, seconds: Double = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

func makeVideo(at url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64, AVVideoHeightKey: 48
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
        ])
    writer.add(input)
    precondition(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixel = buffer!
    CVPixelBufferLockBaseAddress(pixel, [])
    memset(CVPixelBufferGetBaseAddress(pixel), 180, CVPixelBufferGetDataSize(pixel))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    for index in 0..<30 {
        pump(until: { input.isReadyForMoreMediaData })
        precondition(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    input.markAsFinished()
    writer.finishWriting(completionHandler: {})
    pump(until: { writer.status != .writing })
    precondition(writer.status == .completed, writer.error?.localizedDescription ?? "写入测试视频失败")
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-behavior-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let store = temporary.appendingPathComponent("finder-actions.json")
    let first = FinderExtensionService(storeURL: store)
    check("缺失配置时提供初始菜单", !first.actions.isEmpty)
    for action in first.actions { first.remove(action.id) }
    let second = FinderExtensionService(storeURL: store)
    check("删除全部菜单后重新载入仍为空", first.actions.isEmpty && second.actions.isEmpty)
    check("空菜单确实持久化为空数组", (try! JSONDecoder().decode([FinderAction].self, from: Data(contentsOf: store))).isEmpty)

    second.add(.newFile)
    let saved = second.actions
    try! FileManager.default.removeItem(at: store)
    try! FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
    second.remove(saved[0].id)
    check("配置写入失败回滚菜单并给出错误", second.actions == saved && second.lastError != nil)

    let elections = FinderElection.parse("-    com.example.off(1.0)\n+    com.example.on(2.0)\n-    com.example.on(1.0)\n")
    check("读取扩展启用与禁用状态，不把历史版本误当当前状态", elections["com.example.off"] == false && elections["com.example.on"] == true)
    check("无登记输出不能当作启用成功", FinderElection.parse("garbage").isEmpty)

    for kind in [RecorderSource.Kind.display, .area, .window] {
        let source = RecorderSource(id: "probe", kind: kind, title: "", subtitle: "")
        check("录屏声音能力：\(kind.rawValue)", source.supportsSystemAudio == (kind != .window))
    }

    let gamma = DisplayGamma()
    check("未获取 gamma 表时返回失败，状态不冒充成功", !gamma.apply(0.3, to: UInt32.max) && gamma.level(for: UInt32.max) == 1)
    for succeeds in [true, false] {
        let writer = DDCWriter()
        let channel = DDCChannel(succeeds)
        var actual: Bool?
        writer.submit(key: "test", channel: channel, codes: [0x10], value: 40) { result in
            DispatchQueue.main.async { actual = result }
        }
        pump(until: { actual != nil })
        check("DDC 写入\(succeeds ? "成功" : "失败")传回执行结果", actual == succeeds)
    }

    let gif = temporary.appendingPathComponent("animated.gif")
    let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
    for red in [true, false] {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red ? NSColor.red.cgColor : NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        CGImageDestinationAddImage(destination, context.makeImage()!,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(destination))
    let tile = WallpaperTileView(frame: CGRect(x: 0, y: 0, width: 32, height: 32), image: NSImage(contentsOf: gif)!, animated: true)
    func pixels() -> Data {
        let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds)!
        tile.cacheDisplay(in: tile.bounds, to: rep)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }
    let initialPixels = pixels()
    var advanced = false
    pump(until: { advanced = pixels() != initialPixels; return advanced }, seconds: 2)
    check("GIF 平铺逐帧更新画面", advanced)

    let movie = temporary.appendingPathComponent("sample.mov")
    try! makeVideo(at: movie)
    var audioTestFinished = false
    var audioTestError: Error?
    Task { @MainActor in
        defer { audioTestFinished = true }
        do {
            let composition = AVMutableComposition()
            let source = AVURLAsset(url: movie)
            var sourceAssets: [AVAsset] = [source]
            defer { withExtendedLifetime(sourceAssets) {} }
            let video = try await source.loadTracks(withMediaType: .video)[0]
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                .insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.9, preferredTimescale: 48000)), of: video, at: .zero)
            for frequency in [440.0, 880.0] {
                let wave = temporary.appendingPathComponent("tone-\(Int(frequency)).m4a")
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                pcm.frameLength = 48000
                for index in 0..<48000 { pcm.floatChannelData![0][index] = Float(0.1 * sin(2 * .pi * frequency * Double(index) / 48000)) }
                do {
                    let file = try AVAudioFile(forWriting: wave, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1], commonFormat: .pcmFormatFloat32, interleaved: false)
                    try file.write(from: pcm)
                }
                let toneAsset = AVURLAsset(url: wave)
                sourceAssets.append(toneAsset)
                let audio = try await toneAsset.loadTracks(withMediaType: .audio)[0]
                try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                    .insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.9, preferredTimescale: 48000)), of: audio, at: .zero)
            }
            let fixture = temporary.appendingPathComponent("two-audio.mov")
            let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
            try await export.export(to: fixture, as: .mov)
            let sourceCount = try await AVURLAsset(url: fixture).loadTracks(withMediaType: .audio).count
            check("混音测试源包含两条声音轨", sourceCount == 2)
            try await RecordingAudioMixer.mixIfNeeded(at: fixture)
            let mixed = AVURLAsset(url: fixture)
            let tracks = try await mixed.loadTracks(withMediaType: .audio)
            check("混音后只保留一条兼容音轨", tracks.count == 1)
            let videoCount = try await mixed.loadTracks(withMediaType: .video).count
            check("混音保留视频轨", videoCount == 1)
            let reader = try AVAssetReader(asset: mixed)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            precondition(reader.startReading())
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(data)
                var values = [Float](repeating: 0, count: length / 4)
                values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                samples += stride(from: 0, to: values.count, by: 2).map { values[$0] }
            }
            for frequency in [440.0, 880.0] {
                var real = 0.0, imaginary = 0.0
                for (index, sample) in samples.enumerated() {
                    let angle = 2 * Double.pi * frequency * Double(index) / 48000
                    real += Double(sample) * cos(angle)
                    imaginary += Double(sample) * sin(angle)
                }
                let amplitude = 2 * hypot(real, imaginary) / Double(max(samples.count, 1))
                check("成片可解码且包含 \(Int(frequency))Hz 音源", amplitude > 0.02)
            }
        } catch { audioTestError = error }
    }
    pump(until: { audioTestFinished }, seconds: 30)
    precondition(audioTestFinished && audioTestError == nil, "混音失败：\(String(describing: audioTestError))")

    // 壁纸播放策略：所有输入都是策略的输入，任何一条要求暂停就没有别的路径能播回去
    func reason(
        _ inputs: WallpaperPlaybackInputs,
        manual: Bool = false,
        options: WallpaperPlaybackOptions = WallpaperPlaybackOptions()
    ) -> WallpaperPauseReason? {
        WallpaperPlaybackPolicy.globalReason(inputs: inputs, options: options, manualPause: manual)
    }
    func playing(_ key: String, _ inputs: WallpaperPlaybackInputs,
                 options: WallpaperPlaybackOptions = WallpaperPlaybackOptions()) -> Bool {
        WallpaperPlaybackPolicy.isPlaying(displayKey: key, inputs: inputs, options: options, manualPause: false)
    }

    check("默认条件下壁纸正常播放", reason(WallpaperPlaybackInputs()) == nil)

    var locked = WallpaperPlaybackInputs()
    locked.isLocked = true
    check("手动暂停优先于任何系统状态", reason(locked, manual: true) == .manual)
    check("锁屏时停止解码", reason(locked) == .locked)
    check("锁屏对每一块屏都生效", !playing("A", locked) && !playing("B", locked))

    var saver = WallpaperPlaybackInputs()
    saver.screenSaver = true
    check("屏幕保护时停止解码", reason(saver) == .screenSaver)

    var displayAsleep = WallpaperPlaybackInputs()
    displayAsleep.displayAsleep = true
    check("显示器休眠时停止解码", reason(displayAsleep) == .displaySleep)

    var sleeping = WallpaperPlaybackInputs()
    sleeping.systemSleeping = true
    check("整机睡眠时停止解码", reason(sleeping) == .systemSleep)

    var hot = WallpaperPlaybackInputs()
    hot.thermalState = .serious
    check("温度偏高时停止解码", reason(hot) == .thermal)
    var noThermal = WallpaperPlaybackOptions()
    noThermal.pauseOnThermal = false
    check("关掉高温暂停后照常播放", reason(hot, options: noThermal) == nil)

    var lowPower = WallpaperPlaybackInputs()
    lowPower.lowPowerMode = true
    check("低电量模式暂停", reason(lowPower) == .lowPower)
    var noLowPower = WallpaperPlaybackOptions()
    noLowPower.pauseInLowPower = false
    check("关掉低电量模式暂停后照常播放", reason(lowPower, options: noLowPower) == nil)

    var lowBattery = WallpaperPlaybackInputs()
    lowBattery.onBattery = true
    lowBattery.batteryPercent = 15
    check("电量低于阈值时暂停", reason(lowBattery) == .battery)
    lowBattery.batteryPercent = 60
    check("电量回升后继续播放", reason(lowBattery) == nil)
    var noFloor = WallpaperPlaybackOptions()
    noFloor.batteryFloor = 0
    check("电量阈值为 0 时不按电量暂停", reason(lowBattery, options: noFloor) == nil)

    var plugged = WallpaperPlaybackInputs()
    plugged.batteryPercent = 5
    check("插着电源时不受电量阈值影响", reason(plugged) == nil)

    var fullscreen = WallpaperPlaybackInputs()
    fullscreen.fullscreenDisplays = ["A"]
    check("全屏应用只停住被盖住的那块屏", !playing("A", fullscreen) && playing("B", fullscreen))
    var noFullscreen = WallpaperPlaybackOptions()
    noFullscreen.pauseOnFullscreen = false
    check("关掉全屏暂停后那块屏继续播", playing("A", fullscreen, options: noFullscreen))

    let defaultOptions = try! JSONDecoder().decode(WallpaperPlaybackOptions.self, from: Data("{}".utf8))
    check("旧配置缺字段时回落到默认值", defaultOptions == WallpaperPlaybackOptions())
    var custom = WallpaperPlaybackOptions()
    custom.batteryFloor = 0
    custom.pauseOnLock = false
    let roundTrip = try! JSONDecoder().decode(
        WallpaperPlaybackOptions.self,
        from: try! JSONEncoder().encode(custom)
    )
    check("播放开关可以完整存取", roundTrip == custom)

    let player = AVPlayer(url: movie)
    pump(until: { player.currentItem?.presentationSize.width ?? 0 > 1 })
    check("测试视频获得真实播放尺寸", player.currentItem?.presentationSize == CGSize(width: 64, height: 48))
    for fill in WallpaperFill.allCases {
        let view = WallpaperVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: player, fill: fill)
        // KVO 的初始尺寸通知会异步交回主线程；先让它送达再验证布局。
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let frame = view.playerLayer.frame
        switch fill {
        case .center:
            check("视频居中保留原尺寸与中心位置", frame == CGRect(x: 128, y: 66, width: 64, height: 48))
        case .tile:
            let columns = view.playerLayer.superlayer as! CAReplicatorLayer
            let rows = columns.superlayer as! CAReplicatorLayer
            check("视频平铺使用原尺寸并覆盖行列", frame.size == CGSize(width: 64, height: 48) && columns.instanceCount == 5 && rows.instanceCount == 4)
            view.setFrameSize(CGSize(width: 128, height: 96))
            view.layoutSubtreeIfNeeded()
            check("调整尺寸后平铺行列更新", columns.instanceCount == 2 && rows.instanceCount == 2)
        case .fit:
            check("视频适应保留完整画面", frame == CGRect(x: 40, y: 0, width: 240, height: 180))
        case .fill:
            check("视频填充铺满并裁切溢出", frame == CGRect(x: 0, y: -30, width: 320, height: 240))
        case .stretch:
            check("视频拉伸占满画布", frame == CGRect(x: 0, y: 0, width: 320, height: 180))
        }
    }
    player.pause()

    // 视频壁纸的无缝循环与暂停
    guard let loop = WallpaperVideoLoop(url: movie, start: 0, end: 0) else {
        preconditionFailure("无法为测试视频建立循环")
    }
    pump(until: { loop.player.rate > 0 }, seconds: 10)
    check("视频壁纸建好队列播放器并开始播放", loop.player.items().count >= 1 && loop.player.rate > 0)
    loop.setPlaying(false)
    check("暂停后播放速率归零且保留画面", loop.player.rate == 0 && loop.player.currentItem != nil)
    loop.setPlaying(true)
    pump(until: { loop.player.rate > 0 }, seconds: 10)
    check("恢复后重新开始播放", loop.player.rate > 0)
    check("唤醒自检不会把正在播的播放器停掉", loop.restartIfStalled() == false)
    // 测试视频只有 1 秒，跑满 2.5 秒还能在播，说明换轮没有停在 item 末尾
    check("视频壁纸用上了无 seek 的无缝循环", loop.isSeamless)
    pump(until: { Date() > Date().addingTimeInterval(0) }, seconds: 0.1)
    let deadline = Date().addingTimeInterval(2.5)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check("跨过一轮之后仍在播放", loop.player.rate > 0 && loop.player.currentItem?.status != .failed)
    loop.teardown()
}
