//  VideoBezel.swift
//  Aurora — 录屏套壳：把录好的视频塞进设备外壳里
//
//  截图那边的带壳是「一张图 + CoreGraphics 合成」；视频不能逐帧重新编码一遍再拼，
//  所以这里走 AVVideoComposition 的 CoreImage 回调：每帧进来按外壳尺寸重新排版，
//  外壳 PNG 盖在上面（屏幕孔洞是透明的），音轨由 export session 原样带过去。
//
//  刻意不做的事：不叠加投影/背景渐变（外壳素材自己带），不重采样帧率，
//  输出尺寸有上限，避免 4K 外壳把一段五分钟的录屏撑成几个 GB。

import AppKit
import AVFoundation
import CoreImage
import Foundation

enum VideoBezelError: LocalizedError {
    case frameUnavailable
    case noVideoTrack
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .frameUnavailable: return T("读不到设备外壳素材")
        case .noVideoTrack: return T("这段录像没有视频轨道")
        case .exportUnavailable: return T("系统不支持当前的导出方式")
        case .exportFailed(let reason): return reason
        }
    }
}

enum VideoBezel {
    /// 输出宽度上限：外壳原图是 4K 级，压到这个宽度再编码，体积与清晰度比较平衡
    static let maxOutputWidth: CGFloat = 2560

    /// 把 source 套进 frame，写到 destination；progress 在主线程回调 0...1
    static func wrap(
        source: URL,
        frame: DeviceFrame,
        to destination: URL,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoBezelError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let isHEVC = try await isHEVCTrack(track)

        guard let frameURL = ScreenshotService.resourceURL(frame.id + ".png"),
              let frameImage = CIImage(contentsOf: frameURL) else {
            throw VideoBezelError.frameUnavailable
        }

        // 外壳缩放到目标宽度（不放大，最多缩到 2560）
        let bezelWidth = CGFloat(frame.pixelWidth)
        let scale = min(1, maxOutputWidth / max(bezelWidth, 1))
        let renderSize = CGSize(
            width: even(CGFloat(frame.pixelWidth) * scale),
            height: even(CGFloat(frame.pixelHeight) * scale)
        )
        let bezel = frameImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: renderSize))

        // 屏幕孔洞：清单里是左上原点，CoreImage 是左下原点
        let holeTopLeft = frame.screen
        let hole = CGRect(
            x: holeTopLeft.minX * scale,
            y: (CGFloat(frame.pixelHeight) - holeTopLeft.maxY) * scale,
            width: holeTopLeft.width * scale,
            height: holeTopLeft.height * scale
        )

        let orientedSize: CGSize = {
            let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
            return CGSize(width: abs(rect.width), height: abs(rect.height))
        }()

        let composition = AVMutableVideoComposition(asset: asset) { request in
            // 注意：这里绝不能 clampedToExtent()。夹取会把 extent 变成无限大，
            // 后面按 extent 算缩放比例会得到 0，整段视频就只剩外壳、屏幕全黑。
            let source = request.sourceImage
            // 系统的回调给的是「未旋转」的原始帧；屏幕录制一般是 identity，
            // 但为窗口/竖屏素材留一手：尺寸已经等于旋转后的尺寸就不再转一次
            let extent = source.extent
            let alreadyOriented = abs(extent.width - orientedSize.width) < 1
                && abs(extent.height - orientedSize.height) < 1
                && abs(naturalSize.width - orientedSize.width) > 1
            let oriented = alreadyOriented ? source : source.transformed(by: preferred)

            // 孔洞内等比填满（和截图带壳的 fit 规则一致），多出来的部分裁掉
            let fill = max(hole.width / max(oriented.extent.width, 1),
                           hole.height / max(oriented.extent.height, 1))
            let scaled = oriented.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            let placed = scaled
                .transformed(by: CGAffineTransform(
                    translationX: hole.midX - scaled.extent.midX,
                    y: hole.midY - scaled.extent.midY
                ))
                .cropped(to: hole)

            // 孔洞垫黑，比例不吻合时不会漏出透明
            let backdrop = CIImage(color: .black).cropped(to: hole)
            let composed = bezel.composited(over: placed.composited(over: backdrop))
            request.finish(with: composed.cropped(to: CGRect(origin: .zero, size: renderSize)), context: nil)
        }
        composition.renderSize = renderSize

        // 目标目录必须先确认可写：录像目录被挪走 / 只读时，与其让
        // AVAssetExportSession 报一句含糊的「无法写入」，不如在这里说清楚
        let folder = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw VideoBezelError.exportFailed(TF("目标文件夹不可写：%@", folder.path))
        }

        // 先写临时文件，验过体积再落到最终位置，避免留下半截 mp4
        let temp = folder.appendingPathComponent(".aurora-bezel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        // 源是 HEVC 就优先用 HEVC 导出；这条码路走不通再退回 H.264
        let presets = isHEVC
            ? [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
            : [AVAssetExportPresetHighestQuality]
        var lastError: Error = VideoBezelError.exportUnavailable

        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.videoComposition = composition
            session.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: temp)

            // 进度靠轮询：export 的 progress 只在跑起来之后有意义
            let poller = Task { @MainActor in
                while !Task.isCancelled {
                    progress?(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            do {
                try await session.export(to: temp, as: .mp4)
                poller.cancel()
                let bytes = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 4096 else {
                    lastError = VideoBezelError.exportFailed(TF("导出结果是空文件（%@），已放弃", preset))
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                await progress?(1)
                return
            } catch {
                poller.cancel()
                try? FileManager.default.removeItem(at: temp)
                lastError = error
            }
        }

        let ns = lastError as NSError
        throw VideoBezelError.exportFailed(
            TF("%@（%@ %d）", lastError.localizedDescription, ns.domain, ns.code)
        )
    }

    /// 判断源是不是 HEVC：是的话导出也用 HEVC，体积不会被撑大
    private static func isHEVCTrack(_ track: AVAssetTrack) async throws -> Bool {
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.contains { description in
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            return subtype == kCMVideoCodecType_HEVC
        }
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let rounded = value.rounded()
        return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded + 1
    }
}
