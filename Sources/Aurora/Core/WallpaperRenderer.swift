//  WallpaperRenderer.swift
//  Aurora — 把壁纸画到桌面层：每个显示器一个窗口，位于 Finder 壁纸之上、桌面图标之下
//
//  说明：视频 / 动图必须自己画（系统没有播放视频壁纸的接口），
//        所以统一用一个 desktopWindow + 1 的窗口承载，静态图也走这里，
//        这样填充方式、交叉淡入、按工作空间切换都能保持一致。

import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

// MARK: - 几何

enum WallpaperGeometry {
    static func frame(imageSize: CGSize, in bounds: CGRect, fill: WallpaperFill) -> CGRect {
        guard imageSize.width > 1, imageSize.height > 1, bounds.width > 1, bounds.height > 1 else { return bounds }
        switch fill {
        case .stretch, .tile:
            return bounds
        case .center:
            return CGRect(
                x: bounds.midX - imageSize.width / 2,
                y: bounds.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
        case .fill:
            let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .fit:
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}

// MARK: - 视频循环（支持掐头去尾）

/// 用 AVPlayerLooper 做真正的无缝循环：
/// 以前是「播到终点 → seek 回起点 → 再 play」，每次接缝都会有一下停顿或黑帧，
/// 掐头去尾的视频尤其明显。AVPlayerLooper 会把下一轮的 item 提前备好，
/// 换轮发生在渲染管线内部，不经过 seek，所以看不出接缝。
/// 万一 looper 起不来（容器怪异、轨道不可读），退回边界观察者 + seek 的老办法，
/// 至少画面还在动。
final class WallpaperVideoLoop {
    let player: AVQueuePlayer
    private let start: Double
    private let end: Double
    private var looper: AVPlayerLooper?
    private var boundary: Any?
    private var endObserver: NSObjectProtocol?
    private(set) var isPlaying = true

    init?(url: URL, start: Double, end: Double) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0.2 else { return nil }

        self.start = max(0, min(start, duration - 0.2))
        self.end = end > self.start + 0.2 ? min(end, duration) : duration

        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        // 壁纸是本地文件，不需要等缓冲攒够再播；关掉可以减少每次换轮前的等待
        player.automaticallyWaitsToMinimizeStalling = false

        let template = AVPlayerItem(asset: asset)
        let range = CMTimeRange(
            start: CMTime(seconds: self.start, preferredTimescale: 600),
            end: CMTime(seconds: self.end, preferredTimescale: 600)
        )
        let looper = AVPlayerLooper(player: player, templateItem: template, timeRange: range)
        if looper.error == nil, !looper.loopingPlayerItems.isEmpty {
            self.looper = looper
            // 队列自己要能往下走：设成 .none 的话第一轮播完就停在 item 末尾，循环就断了
            player.actionAtItemEnd = .advance
        } else {
            self.looper = nil
            player.insert(AVPlayerItem(asset: asset), after: nil)
            player.actionAtItemEnd = .none
            installFallbackLooping()
        }

        player.play()
    }

    /// 是否用上了真正的无缝循环（回退路径会有一次接缝）
    var isSeamless: Bool { looper != nil }

    /// 回退路径：到裁剪终点就 seek 回起点
    private func installFallbackLooping() {
        let itemDuration = player.currentItem?.duration.seconds ?? .infinity
        if end > start + 0.05, end < itemDuration {
            let time = CMTime(seconds: end, preferredTimescale: 600)
            boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
                self?.seekToStart()
            }
        } else {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.seekToStart()
            }
        }
        seekToStart()
    }

    private func seekToStart() {
        let target = CMTime(seconds: start, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.player.play()
        }
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing {
            play()
        } else {
            pause()
        }
    }

    func play() {
        isPlaying = true
        if player.rate == 0 { player.play() }
    }

    func pause() {
        isPlaying = false
        if player.rate != 0 { player.pause() }
    }

    /// 唤醒后发现播放器停住（rate 归零或 item 失败）时重建，避免显示一张冻住的黑画面
    func restartIfStalled() -> Bool {
        if player.currentItem?.status == .failed {
            player.play()
            return true
        }
        if isPlaying, player.rate == 0 {
            player.play()
            return true
        }
        return false
    }

    func teardown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.removeAllItems()
    }
}

// MARK: - 平铺视图

final class WallpaperTileView: NSView {
    private var pattern: NSColor?
    private var bitmap: NSBitmapImageRep?
    private var timer: Timer?
    private var frameIndex = 0
    private var frameCount = 1
    private var isRunning = true
    private let imageSize: NSSize

    init(frame: NSRect, image: NSImage, animated: Bool) {
        imageSize = image.size
        pattern = NSColor(patternImage: image)
        super.init(frame: frame)
        if animated, let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            frameCount = (rep.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 1
            if frameCount > 1 {
                bitmap = rep
                updateFrame()
            }
        }
    }

    deinit { timer?.invalidate() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    /// 暂停时不推进帧（锁屏、低电量时没必要定时唤醒主线程）
    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if running {
            scheduleNextFrame(duration: currentFrameDuration)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private var currentFrameDuration: Double {
        let duration = (bitmap?.value(forProperty: .currentFrameDuration) as? NSNumber)?.doubleValue ?? 0.1
        return duration.isFinite && duration > 0 ? max(duration, 0.02) : 0.1
    }

    private func updateFrame() {
        guard let bitmap else { return }
        bitmap.setProperty(.currentFrame, withValue: NSNumber(value: frameIndex))
        if let cgImage = bitmap.cgImage {
            pattern = NSColor(patternImage: NSImage(cgImage: cgImage, size: imageSize))
            needsDisplay = true
        }
        scheduleNextFrame(duration: currentFrameDuration)
    }

    private func scheduleNextFrame(duration: Double) {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        let next = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frameCount
            self.updateFrame()
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        pattern?.setFill()
        dirtyRect.fill()
    }
}

// MARK: - 单个内容槽

private final class WallpaperSlotView: NSView {
    private var imageView: NSImageView?
    private var tileView: WallpaperTileView?
    private var videoView: WallpaperVideoView?
    private var videoLoop: WallpaperVideoLoop?
    private var proceduralView: NSHostingView<ProceduralWallpaperView>?
    private var fill: WallpaperFill = .fill
    private var isPlaying = true
    /// 非平铺的动图走 NSImageView.animates，暂停时要单独关掉
    private var isAnimatedImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    /// 程序化场景的计时器按持有者计数，多个槽位互不覆盖
    private var playbackToken: String { String(describing: ObjectIdentifier(self)) }

    func configure(item: WallpaperItem, fill: WallpaperFill) {
        teardown()
        self.fill = fill

        switch item.kind {
        case .procedural:
            let hosting = NSHostingView(
                rootView: ProceduralWallpaperView(style: item.style ?? "aurora", hueShift: item.hue ?? 0)
            )
            hosting.frame = bounds
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            addSubview(hosting)
            imageView = nil
            proceduralView = hosting
            ProceduralClock.shared.setPlaying(isPlaying, token: playbackToken)

        case .image, .gif:
            guard let image = NSImage(contentsOf: item.url) else { return }
            if fill == .tile {
                let view = WallpaperTileView(frame: bounds, image: image, animated: item.kind == .gif)
                addSubview(view)
                tileView = view
                view.setRunning(isPlaying)
            } else {
                let view = NSImageView(frame: bounds)
                view.image = image
                isAnimatedImage = item.kind == .gif
                view.animates = isAnimatedImage && isPlaying
                view.imageScaling = .scaleAxesIndependently
                view.imageFrameStyle = .none
                view.wantsLayer = true
                addSubview(view)
                imageView = view
                layoutContent()
            }

        case .video:
            guard let loop = WallpaperVideoLoop(url: item.url, start: item.trimStart, end: item.trimEnd) else { return }
            let view = WallpaperVideoView(frame: bounds, player: loop.player, fill: fill)
            addSubview(view)
            videoView = view
            videoLoop = loop
            loop.setPlaying(isPlaying)
        }
    }

    /// 播放 / 暂停当前内容。暂停只是停住，画面留在最后一帧，不会变黑。
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        videoLoop?.setPlaying(playing)
        tileView?.setRunning(playing)
        if isAnimatedImage { imageView?.animates = playing }
        if proceduralView != nil {
            ProceduralClock.shared.setPlaying(playing, token: playbackToken)
        }
    }

    /// 唤醒后播放器可能卡在 rate = 0 或失败的 item 上，重试一次
    func recoverIfStalled() {
        _ = videoLoop?.restartIfStalled()
    }

    private func layoutContent() {
        if let imageView, let image = imageView.image {
            imageView.frame = WallpaperGeometry.frame(imageSize: image.size, in: bounds, fill: fill)
        }
        tileView?.frame = bounds
        videoView?.frame = bounds
    }

    func teardown() {
        videoLoop?.teardown()
        videoLoop = nil
        videoView?.removeFromSuperview()
        videoView = nil
        imageView?.removeFromSuperview()
        imageView = nil
        isAnimatedImage = false
        tileView?.removeFromSuperview()
        tileView = nil
        proceduralView?.removeFromSuperview()
        proceduralView = nil
        ProceduralClock.shared.forget(token: playbackToken)
    }
}

// MARK: - 一块屏幕的画面（两层做交叉淡入）

final class WallpaperSurfaceView: NSView {
    private let slotA = WallpaperSlotView(frame: .zero)
    private let slotB = WallpaperSlotView(frame: .zero)
    private var frontIsA = true
    private(set) var currentID: String?
    private var currentFill: WallpaperFill?
    private var currentTrim: String?
    private(set) var isPlaying = true
    /// 每次切换加一，防止淡出回调把刚切进来的内容拆掉
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for slot in [slotA, slotB] {
            slot.frame = bounds
            slot.autoresizingMask = [.width, .height]
            slot.alphaValue = 0
            addSubview(slot)
        }
        slotA.alphaValue = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 这块屏该不该动（锁屏 / 休眠 / 低电量 / 被全屏应用盖住都由策略决定）
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        slotA.setPlaying(playing)
        slotB.setPlaying(playing)
    }

    func recoverIfStalled() {
        slotA.recoverIfStalled()
        slotB.recoverIfStalled()
    }

    func show(item: WallpaperItem, fill: WallpaperFill, animated: Bool) {
        // 签名里带上色相偏移：自定义配色后同一条目也要重渲染
        let trim = String(format: "%.2f-%.2f|hue:%.0f|style:%@",
                          item.trimStart, item.trimEnd, item.hue ?? 0, item.style ?? "")
        if currentID == item.id, currentFill == fill, currentTrim == trim { return }

        generation += 1
        let currentGeneration = generation
        let incoming = frontIsA ? slotB : slotA
        let outgoing = frontIsA ? slotA : slotB

        incoming.layer?.removeAllAnimations()
        incoming.alphaValue = 0
        // 先把播放状态交给新槽位：configure 建播放器时才会带着「该不该动」的正确状态
        incoming.setPlaying(isPlaying)
        incoming.configure(item: item, fill: fill)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.7
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                incoming.animator().alphaValue = 1
                outgoing.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                // 淡出结束后停掉旧视频，避免两路视频一起解码
                outgoing.teardown()
            }
        } else {
            outgoing.alphaValue = 0
            outgoing.teardown()
            incoming.alphaValue = 1
        }

        frontIsA.toggle()
        currentID = item.id
        currentFill = fill
        currentTrim = trim
    }

    func clear() {
        slotA.teardown()
        slotB.teardown()
        currentID = nil
        currentFill = nil
        currentTrim = nil
    }
}

// MARK: - 桌面层窗口

final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 渲染器

@MainActor
final class WallpaperRenderer {
    private var windows: [String: WallpaperWindow] = [:]
    private var surfaces: [String: WallpaperSurfaceView] = [:]

    var activeCount: Int { windows.count }

    func sync(screens: [ScreenTarget]) {
        let valid = Set(screens.map(\.key))
        for (key, window) in windows where !valid.contains(key) {
            window.orderOut(nil)
            surfaces[key]?.clear()
            windows[key] = nil
            surfaces[key] = nil
        }

        for target in screens {
            if let window = windows[target.key] {
                if window.frame != target.screen.frame {
                    window.setFrame(target.screen.frame, display: true)
                }
            } else {
                let window = WallpaperWindow(screen: target.screen)
                let surface = WallpaperSurfaceView(frame: NSRect(origin: .zero, size: target.screen.frame.size))
                surface.autoresizingMask = [.width, .height]
                window.contentView = surface
                window.setFrame(target.screen.frame, display: true)
                window.orderFrontRegardless()
                windows[target.key] = window
                surfaces[target.key] = surface
            }
        }
    }

    func show(item: WallpaperItem, fill: WallpaperFill, on key: String, screen: NSScreen, animated: Bool) {
        if windows[key] == nil {
            sync(screens: [ScreenTarget(key: key, screen: screen)])
        }
        guard let surface = surfaces[key], let window = windows[key] else { return }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        surface.show(item: item, fill: fill, animated: animated)
        window.orderFrontRegardless()
    }

    func clear(key: String) {
        surfaces[key]?.clear()
        windows[key]?.orderOut(nil)
        windows[key] = nil
        surfaces[key] = nil
    }

    /// 按屏下发播放状态；没有出现在字典里的屏保持原样
    func setPlaying(_ playing: [String: Bool]) {
        for (key, value) in playing {
            surfaces[key]?.setPlaying(value)
        }
    }

    /// 唤醒后把所有卡的播放器踢一下
    func recoverStalledPlayers() {
        for surface in surfaces.values { surface.recoverIfStalled() }
    }

    func clearAll() {
        for key in windows.keys { surfaces[key]?.clear() }
        for window in windows.values {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        surfaces.removeAll()
    }
}

struct ScreenTarget {
    let key: String
    let screen: NSScreen
}
