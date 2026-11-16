import AppKit
import AVFoundation
import QuartzCore

/// 一条解码链路，用图层复制实现同步平铺。作者：wwj。
final class WallpaperVideoView: NSView {
    let playerLayer: AVPlayerLayer
    private let columns = CAReplicatorLayer()
    private let rows = CAReplicatorLayer()
    private let fill: WallpaperFill
    private let player: AVPlayer
    private var sizeObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var videoSize = CGSize.zero

    init(frame: NSRect, player: AVPlayer, fill: WallpaperFill) {
        self.fill = fill
        self.player = player
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(rows)
        rows.addSublayer(columns)
        columns.addSublayer(playerLayer)
        // presentationSize 就绪前为零；等实际尺寸到达后重新布局。
        attachSizeObservation()
        // 无缝循环会在队列里换 item，currentItem 出现得晚就不能漏掉尺寸通知
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.attachSizeObservation() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func attachSizeObservation() {
        guard sizeObservation == nil, let item = player.currentItem else { return }
        sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            DispatchQueue.main.async {
                self?.videoSize = size
                self?.needsLayout = true
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        rows.frame = bounds
        columns.frame = bounds
        let validSize = videoSize.width > 1 && videoSize.height > 1
        if fill == .tile, validSize {
            playerLayer.frame = CGRect(origin: .zero, size: videoSize)
            playerLayer.videoGravity = .resize
            columns.instanceCount = max(1, Int(ceil(bounds.width / videoSize.width)))
            rows.instanceCount = max(1, Int(ceil(bounds.height / videoSize.height)))
            columns.instanceTransform = CATransform3DMakeTranslation(videoSize.width, 0, 0)
            rows.instanceTransform = CATransform3DMakeTranslation(0, videoSize.height, 0)
        } else {
            rows.instanceCount = 1
            columns.instanceCount = 1
            playerLayer.frame = WallpaperGeometry.frame(imageSize: videoSize, in: bounds, fill: fill)
            playerLayer.videoGravity = .resizeAspect
            if fill == .stretch { playerLayer.videoGravity = .resize }
        }
    }
}
