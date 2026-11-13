//  CameraBubble.swift
//  Aurora — 画中画摄像头气泡（Snapzy 同款）
//
//  录制时在屏幕角落悬浮一个可拖动的摄像头预览气泡。窗口放在 screenSaver 层，
//  SCStream 的整屏采集会把它一并录进画面——这正是画中画的效果。
//  拖动直接改窗口 frame；关闭按钮停止预览并隐藏。
//
//  注意：App 的 Info.plist 必须有 NSCameraUsageDescription，否则一碰摄像头
//  就会被 TCC 直接杀掉进程（之前「画中画完全不可用」就是这个原因）。

import AppKit
import AVFoundation

@MainActor
final class CameraBubble {
    static let shared = CameraBubble()

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var contentView: BubbleContentView?
    private let sessionQueue = DispatchQueue(label: "aurora.camera.bubble")

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        guard panel == nil else {
            panel?.orderFrontRegardless()
            return
        }
        Task { await startCamera() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        contentView = nil
        if let session {
            sessionQueue.async { session.stopRunning() }
        }
        session = nil
    }

    private func startCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard granted else {
            auroraDelegate?.state.showToast(T("需要摄像头权限才能显示画中画"), symbol: "video.slash")
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            auroraDelegate?.state.showToast(T("没有可用的摄像头"), symbol: "video.slash")
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            auroraDelegate?.state.showToast(T("摄像头打开失败"), symbol: "video.slash")
            return
        }
        session.commitConfiguration()
        self.session = session

        // 按摄像头实际比例定气泡尺寸（外接摄像头常见 16:9，内建多为 16:10）
        let aspect = Self.aspect(of: device)
        let width: CGFloat = 244
        let height = (width / aspect).rounded()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: screen.maxX - width - 24,
            y: screen.minY + 56,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let content = BubbleContentView(closeAction: { [weak self] in self?.hide() })
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        panel.contentView = content
        self.contentView = content
        self.panel = panel

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = content.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // 内建摄像头水平镜像，符合「照镜子」的直觉
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        content.layer?.insertSublayer(preview, at: 0)
        panel.orderFrontRegardless()

        // startRunning 会阻塞，别放在主线程
        sessionQueue.async { session.startRunning() }
    }

    private static func aspect(of device: AVCaptureDevice) -> CGFloat {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }
}

/// 可拖动的气泡内容视图（自带关闭按钮）
final class BubbleContentView: NSView {
    private let closeAction: () -> Void
    private var downGlobal: NSPoint?
    private var downWindowFrame: NSRect?

    init(closeAction: @escaping () -> Void) {
        self.closeAction = closeAction
        super.init(frame: .zero)
        let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!, target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .white
        button.alphaValue = 0.8
        button.target = self
        button.action = #selector(closeClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeClicked() { closeAction() }

    override var acceptsFirstResponder: Bool { false }

    /// 关闭按钮自己接收点击，其余区域拖动窗口
    override func hitTest(_ point: NSPoint) -> NSView? {
        for sub in subviews where sub.frame.insetBy(dx: -2, dy: -2).contains(point) {
            return sub
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        downGlobal = NSEvent.mouseLocation
        downWindowFrame = window?.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downWindowFrame, let down = downGlobal else { return }
        let current = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: start.minX + (current.x - down.x),
            y: start.minY + (current.y - down.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        downGlobal = nil
        downWindowFrame = nil
    }
}
