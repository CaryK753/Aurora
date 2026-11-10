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

extension WallpaperFill {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit, .center: return .resizeAspect
        case .stretch: return .resize
        case .tile: return .resizeAspectFill
        }
    }
}

// MARK: - 视频循环（支持掐头去尾）

final class WallpaperVideoLoop {
    let player: AVPlayer
    private let start: Double
    private let end: Double
    private var boundary: Any?
    private var endObserver: NSObjectProtocol?

    init?(url: URL, start: Double, end: Double) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0.2 else { return nil }

        self.start = max(0, min(start, duration - 0.2))
        let requestedEnd = end > self.start + 0.2 ? min(end, duration) : 0
        self.end = requestedEnd
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false

        configureLooping()
        seekToStart(autoplay: true)
    }

    private func configureLooping() {
        if end > start {
            // 到裁剪终点就回到起点，用边界时间观察者比监听播放结束更准
            let time = CMTime(seconds: end, preferredTimescale: 600)
            boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
                self?.seekToStart(autoplay: true)
            }
        } else {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.seekToStart(autoplay: true)
            }
        }
    }

    private func seekToStart(autoplay: Bool) {
        let target = CMTime(seconds: start, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, autoplay else { return }
            self.player.play()
        }
    }

    func play() {
        if player.rate == 0 { player.play() }
    }

    func pause() {
        if player.rate != 0 { player.pause() }
    }

    func teardown() {
        player.pause()
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - 平铺视图

private final class WallpaperTileView: NSView {
    private let pattern: NSColor?

    init(frame: NSRect, image: NSImage) {
        pattern = NSColor(patternImage: image)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        pattern?.setFill()
        dirtyRect.fill()
    }
}

// MARK: - 单个内容槽

private final class WallpaperSlotView: NSView {
    private var imageView: NSImageView?
    private var tileView: WallpaperTileView?
    private var playerLayer: AVPlayerLayer?
    private var videoLoop: WallpaperVideoLoop?
    private var proceduralView: NSHostingView<ProceduralWallpaperView>?
    private var fill: WallpaperFill = .fill

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

        case .image, .gif:
            guard let image = NSImage(contentsOf: item.url) else { return }
            if fill == .tile {
                let view = WallpaperTileView(frame: bounds, image: image)
                addSubview(view)
                tileView = view
            } else {
                let view = NSImageView(frame: bounds)
                view.image = image
                view.animates = (item.kind == .gif)
                view.imageScaling = .scaleAxesIndependently
                view.imageFrameStyle = .none
                view.wantsLayer = true
                addSubview(view)
                imageView = view
                layoutContent()
            }

        case .video:
            guard let loop = WallpaperVideoLoop(url: item.url, start: item.trimStart, end: item.trimEnd) else { return }
            let layer = AVPlayerLayer(player: loop.player)
            layer.frame = bounds
            layer.videoGravity = fill.videoGravity
            layer.backgroundColor = NSColor.black.cgColor
            wantsLayer = true
            self.layer?.addSublayer(layer)
            playerLayer = layer
            videoLoop = loop
            loop.play()
        }
    }

    private func layoutContent() {
        if let imageView, let image = imageView.image {
            imageView.frame = WallpaperGeometry.frame(imageSize: image.size, in: bounds, fill: fill)
        }
        tileView?.frame = bounds
        playerLayer?.frame = bounds
    }

    func teardown() {
        videoLoop?.teardown()
        videoLoop = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        imageView?.removeFromSuperview()
        imageView = nil
        tileView?.removeFromSuperview()
        tileView = nil
        proceduralView?.removeFromSuperview()
        proceduralView = nil
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
