//  CameraBubble.swift
//  Aurora — 画中画摄像头气泡
//
//  录制时在屏幕角落悬浮一个可拖动的摄像头预览。窗口本身是普通 App 窗口
//  （sharingType = .readOnly），ScreenCaptureKit 会把它的画面一并录进视频——
//  这就是画中画的效果。录制管线只在「不录制 Aurora 自己的界面」时把它单独
//  「例外包含」进来（见 RecorderService.overlayWindowIDs）。
//
//  参考 Snapzy 的 RecordingCameraOverlayWindow：
//  · 形状（圆角矩形 / 正方形 / 圆形）、尺寸（小 / 中 / 大）、镜像
//  · 摄像头设备可选（内建 / 连续互通相机 / 外接），拔出自动切回默认
//  · 会话中断、媒体服务重启后自动恢复
//  · 位置与外观都记住，右键可改形状 / 尺寸 / 镜像 / 设备
//
//  权限：Info.plist 的 NSCameraUsageDescription + entitlements 的
//  com.apple.security.device.camera 缺一不可（hardened runtime 会被 TCC 直接拦）
//  否则表现就是「打开画中画什么都没发生」。

import AppKit
import AVFoundation

@MainActor
final class CameraBubble: ObservableObject {
    static let shared = CameraBubble()

    // MARK: 外观

    enum Shape: String, CaseIterable, Identifiable {
        case rectangle, square, circle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rectangle: return T("圆角矩形")
            case .square: return T("正方形")
            case .circle: return T("圆形")
            }
        }
        var symbol: String {
            switch self {
            case .rectangle: return "rectangle"
            case .square: return "square"
            case .circle: return "circle"
            }
        }
        /// 宽高比：矩形跟着摄像头走，方形 / 圆形固定 1:1
        var aspectRatio: CGFloat? {
            self == .rectangle ? nil : 1
        }
        func cornerRadius(for size: CGSize) -> CGFloat {
            switch self {
            case .rectangle: return 18
            case .square: return 22
            case .circle: return min(size.width, size.height) / 2
            }
        }
    }

    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: return T("小")
            case .medium: return T("中")
            case .large: return T("大")
            }
        }
        func baseSize(for shape: Shape, cameraAspect: CGFloat) -> CGSize {
            switch shape {
            case .rectangle:
                switch self {
                case .small: return CGSize(width: 168, height: 168 / max(cameraAspect, 0.5))
                case .medium: return CGSize(width: 224, height: 224 / max(cameraAspect, 0.5))
                case .large: return CGSize(width: 288, height: 288 / max(cameraAspect, 0.5))
                }
            case .square, .circle:
                switch self {
                case .small: return CGSize(width: 140, height: 140)
                case .medium: return CGSize(width: 180, height: 180)
                case .large: return CGSize(width: 224, height: 224)
                }
            }
        }
    }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let isContinuity: Bool
    }

    static let defaultDeviceID = "system-default"

    // MARK: 状态

    @Published private(set) var isVisible = false
    @Published private(set) var isCameraRunning = false
    /// 摄像头权限被拒时为 true，界面据此提示「去授权」
    @Published private(set) var isDenied = false

    @Published var shape: Shape {
        didSet { ud.set(shape.rawValue, forKey: Keys.shape); applyAppearance() }
    }
    @Published var size: Size {
        didSet {
            // 手动拖过大小之后，选预设就回到预设
            customWidth = nil
            ud.removeObject(forKey: Keys.customWidth)
            ud.set(size.rawValue, forKey: Keys.size)
            applyAppearance()
        }
    }
    @Published var mirrored: Bool {
        didSet { ud.set(mirrored, forKey: Keys.mirrored); applyMirror() }
    }
    @Published var deviceID: String {
        didSet {
            guard deviceID != oldValue else { return }
            ud.set(deviceID, forKey: Keys.device)
            cameraAspect = 0
            restartSession()
            applyAppearance()
        }
    }

    /// 用户点气泡上的 ✕：交给录制页把开关关掉
    var onClose: (() -> Void)?
    /// 权限缺失 / 没有摄像头：交给录制页提示并关掉开关
    var onUnavailable: ((String) -> Void)?

    private enum Keys {
        static let shape = "recorder.pip.shape"
        static let size = "recorder.pip.size"
        static let mirrored = "recorder.pip.mirrored"
        static let device = "recorder.pip.device"
        static let customWidth = "recorder.pip.customWidth"
        static let position = "recorder.pip.position"
        static let positionScreen = "recorder.pip.positionScreen"
    }

    private let ud = UserDefaults.standard
    private var panel: NSPanel?
    private var previewView: CameraPreviewView?
    private var session: AVCaptureSession?
    private var currentDeviceID: String?
    private var sessionObservers: [NSObjectProtocol] = []
    private let sessionQueue = DispatchQueue(label: "aurora.camera.session")
    private weak var targetScreen: NSScreen?
    /// 摄像头实际画面比例，用来给矩形形状定高
    private var cameraAspect: CGFloat = 16.0 / 9.0
    /// 手动拖拽后的宽度（点）；nil 表示用预设尺寸
    private var customWidth: CGFloat?
    /// 正在请求权限，避免重复弹框
    private var isRequesting = false
    private var isStarting = false
    /// 权限被拒后轮询授权状态，用户在系统设置里放行后自动恢复画面
    private var authPollTimer: Timer?

    private init() {
        shape = Shape(rawValue: ud.string(forKey: Keys.shape) ?? "") ?? .rectangle
        size = Size(rawValue: ud.string(forKey: Keys.size) ?? "") ?? .medium
        mirrored = ud.object(forKey: Keys.mirrored) as? Bool ?? true
        deviceID = ud.string(forKey: Keys.device) ?? Self.defaultDeviceID
        if let width = ud.object(forKey: Keys.customWidth) as? Double, width >= 100 {
            customWidth = CGFloat(width)
        }
    }

    // MARK: - 设备

    nonisolated static func availableDevices() -> [Device] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.continuityCamera, .external, .deskViewCamera]
        } else {
            types += [.externalUnknown, .deskViewCamera]
        }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return session.devices.map {
            Device(id: $0.uniqueID, name: $0.localizedName, isContinuity: $0.isContinuityCamera)
        }
    }

    /// 当前选中设备的显示名（气泡占位文案用）
    var deviceDisplayName: String {
        guard deviceID != Self.defaultDeviceID else { return T("默认摄像头") }
        return Self.availableDevices().first { $0.id == deviceID }?.name ?? T("摄像头不可用")
    }

    private func resolvedDevice() -> AVCaptureDevice? {
        if deviceID != Self.defaultDeviceID,
           let device = Self.captureDevice(withID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .video) ?? Self.availableDevices().first.flatMap {
            Self.captureDevice(withID: $0.id)
        }
    }

    private nonisolated static func captureDevice(withID id: String) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = {
            if #available(macOS 14.0, *) {
                return [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera]
            }
            return [.builtInWideAngleCamera, .externalUnknown, .deskViewCamera]
        }()
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return session.devices.first { $0.uniqueID == id }
    }

    // MARK: - 显示 / 隐藏

    /// 只把窗口建出来（不显示、不开摄像头）：录制开始前用它拿到 window ID，
    /// 好在 SCContentFilter 里把气泡「例外包含」进画面
    @discardableResult
    func prepare(on screen: NSScreen?) -> CGWindowID? {
        targetScreen = screen ?? targetScreen
        guard let panel = ensurePanel() else { return nil }
        Debug.log("camera: prepared #\(panel.windowNumber) frame=\(panel.frame)")
        return CGWindowID(panel.windowNumber)
    }

    /// 显示气泡并打开摄像头
    func show(on screen: NSScreen? = nil) {
        if let screen { targetScreen = screen }
        guard let panel = ensurePanel() else { return }
        applyAppearance()
        panel.orderFrontRegardless()
        isVisible = true
        Debug.log("camera: bubble shown frame=\(panel.frame) screen=\(panel.screen?.localizedName ?? "-")")
        startCameraIfNeeded()
    }

    func hide() {
        stopAuthPolling()
        panel?.orderOut(nil)
        isVisible = false
        stopCamera()
    }

    /// 录制结束彻底收掉
    func teardown() {
        hide()
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers = []
        panel?.close()
        panel = nil
        previewView = nil
    }

    /// 权限被拒时跳系统设置
    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 窗口

    private func ensurePanel() -> NSPanel? {
        if let panel { return panel }

        let screen = targetScreen ?? Self.targetScreenFallback()
        let size = bubbleSize()
        let origin = restoredOrigin(size: size, on: screen)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        // 默认 .readOnly：允许被 ScreenCaptureKit 录到
        panel.sharingType = .readOnly

        let content = CameraPreviewView(frame: NSRect(origin: .zero, size: size))
        content.onDragEnded = { [weak self] in self?.persistOrigin() }
        content.onResized = { [weak self] width in self?.persistWidth(width) }
        content.onClose = { [weak self] in self?.handleClose() }
        content.onMenu = { [weak self] in self?.buildContextMenu() }
        panel.contentView = content

        self.panel = panel
        self.previewView = content
        applyAppearance()
        if let session { content.attach(session: session) }
        return panel
    }

    private static func targetScreenFallback() -> NSScreen {
        ScreenshotService.builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
        ?? NSScreen.screens[0]
    }

    private func bubbleSize() -> CGSize {
        var target = size.baseSize(for: shape, cameraAspect: cameraAspect)
        if let customWidth {
            let ratio = shape.aspectRatio ?? max(cameraAspect, 0.5)
            target = CGSize(width: customWidth, height: customWidth / ratio)
        }
        // 小屏幕上别把气泡撑到和屏幕一样大
        let screen = targetScreen ?? Self.targetScreenFallback()
        let usable = CGSize(width: screen.visibleFrame.width - 48, height: screen.visibleFrame.height - 96)
        var width = min(target.width, usable.width)
        var height = min(target.height, usable.height)
        if let ratio = shape.aspectRatio {
            height = width / ratio
            if height > usable.height {
                height = usable.height
                width = height * ratio
            }
        } else if let cameraRatio = cameraAspect > 0 ? cameraAspect : nil {
            height = width / cameraRatio
            if height > usable.height {
                height = usable.height
                width = height * cameraRatio
            }
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private func applyAppearance() {
        guard let panel, let previewView else { return }
        let size = bubbleSize()
        let screen = targetScreen ?? Self.targetScreenFallback()
        var frame = panel.frame
        // 以右下角为锚点调整大小，换形状时不会跳到屏幕外
        let maxX = frame.maxX
        let minY = frame.minY
        frame.size = size
        frame.origin = NSPoint(x: maxX - size.width, y: minY)
        frame = clamped(frame, on: screen)
        panel.setFrame(frame, display: true)
        previewView.frame = NSRect(origin: .zero, size: size)
        previewView.apply(shape: shape, mirrored: mirrored, deviceName: deviceDisplayName, denied: isDenied)
    }

    private func applyMirror() {
        previewView?.apply(shape: shape, mirrored: mirrored, deviceName: deviceDisplayName, denied: isDenied)
    }

    private func handleClose() {
        hide()
        onClose?()
    }

    // MARK: - 位置

    private func restoredOrigin(size: CGSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        if let stored = ud.dictionary(forKey: Keys.position) as? [String: Double],
           let fx = stored["x"], let fy = stored["y"] {
            let point = NSPoint(
                x: visible.minX + CGFloat(fx) * visible.width,
                y: visible.minY + CGFloat(fy) * visible.height
            )
            let frame = NSRect(origin: point, size: size)
            return clamped(frame, on: screen).origin
        }
        return clamped(
            NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 56, width: size.width, height: size.height),
            on: screen
        ).origin
    }

    private func clamped(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(result.minY, visible.minY), max(visible.minY, visible.maxY - result.height))
        return result
    }

    private func persistWidth(_ width: CGFloat) {
        let screen = targetScreen ?? Self.targetScreenFallback()
        let clamped = min(max(width, 120), max(160, screen.visibleFrame.width * 0.55))
        customWidth = clamped
        ud.set(Double(clamped), forKey: Keys.customWidth)
        applyAppearance()
    }

    private func persistOrigin() {
        guard let panel, let screen = panel.screen ?? targetScreen else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }
        ud.set([
            "x": Double((panel.frame.minX - visible.minX) / visible.width),
            "y": Double((panel.frame.minY - visible.minY) / visible.height),
        ], forKey: Keys.position)
    }

    // MARK: - 右键菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let shapeItem = NSMenuItem(title: T("形状"), action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        for option in Shape.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(menuPickShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == shape ? .on : .off
            item.image = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil)
            shapeMenu.addItem(item)
        }
        shapeItem.submenu = shapeMenu
        menu.addItem(shapeItem)

        let sizeItem = NSMenuItem(title: T("大小"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for option in Size.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(menuPickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == size ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let mirror = NSMenuItem(title: T("镜像画面"), action: #selector(menuToggleMirror), keyEquivalent: "")
        mirror.target = self
        mirror.state = mirrored ? .on : .off
        menu.addItem(mirror)

        let devices = Self.availableDevices()
        if !devices.isEmpty {
            menu.addItem(.separator())
            let deviceItem = NSMenuItem(title: T("摄像头"), action: nil, keyEquivalent: "")
            let deviceMenu = NSMenu()
            let system = NSMenuItem(title: T("系统默认"), action: #selector(menuPickDevice(_:)), keyEquivalent: "")
            system.target = self
            system.representedObject = Self.defaultDeviceID
            system.state = deviceID == Self.defaultDeviceID ? .on : .off
            deviceMenu.addItem(system)
            for device in devices {
                let item = NSMenuItem(
                    title: device.isContinuity ? TF("%@（连续互通）", device.name) : device.name,
                    action: #selector(menuPickDevice(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.id
                item.state = device.id == deviceID ? .on : .off
                deviceMenu.addItem(item)
            }
            deviceItem.submenu = deviceMenu
            menu.addItem(deviceItem)
        }

        menu.addItem(.separator())
        let close = NSMenuItem(title: T("关闭画中画"), action: #selector(menuClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func menuPickShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = Shape(rawValue: raw) else { return }
        shape = option
    }

    @objc private func menuPickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = Size(rawValue: raw) else { return }
        size = option
    }

    @objc private func menuToggleMirror() {
        mirrored.toggle()
    }

    @objc private func menuPickDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        deviceID = id
    }

    @objc private func menuClose() {
        handleClose()
    }

    // MARK: - 采集会话

    /// 权限没批时定期看一眼：授权了就重开会话，气泡始终留在屏幕上
    private func startAuthPolling() {
        authPollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDenied, self.isVisible else {
                    self?.authPollTimer?.invalidate()
                    self?.authPollTimer = nil
                    return
                }
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
                self.authPollTimer?.invalidate()
                self.authPollTimer = nil
                Debug.log("camera: authorized, resuming session")
                self.isDenied = false
                self.startCameraIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        authPollTimer = timer
    }

    private func stopAuthPolling() {
        authPollTimer?.invalidate()
        authPollTimer = nil
    }

    private func startCameraIfNeeded() {
        guard !isStarting else { return }
        isStarting = true
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.requestAccessIfNeeded()
            self.isStarting = false
            Debug.log("camera: access granted=\(granted) status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            guard granted else {
                self.isDenied = true
                self.previewView?.apply(shape: self.shape, mirrored: self.mirrored,
                                        deviceName: T("未获得摄像头权限"), denied: true)
                // 气泡留在屏幕上显示原因；用户去系统设置授权后自动恢复画面
                self.onUnavailable?(T("需要摄像头权限才能显示画中画"))
                self.startAuthPolling()
                return
            }
            self.isDenied = false
            self.startSession()
        }
    }

    private func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            guard !isRequesting else { return false }
            isRequesting = true
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isRequesting = false
            return granted
        default: return false
        }
    }

    private func startSession() {
        guard let device = resolvedDevice() else {
            Debug.log("camera: no device available")
            previewView?.apply(shape: shape, mirrored: mirrored, deviceName: T("没有可用的摄像头"), denied: true)
            onUnavailable?(T("没有可用的摄像头"))
            isDenied = true
            return
        }
        // 已经是这台设备就不用重建
        if let session, currentDeviceID == device.uniqueID, session.isRunning {
            previewView?.attach(session: session)
            return
        }

        stopCamera()

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                Debug.log("camera: cannot add input")
                session.commitConfiguration()
                previewView?.apply(shape: shape, mirrored: mirrored, deviceName: T("摄像头不可用"), denied: true)
                onUnavailable?(T("摄像头打开失败"))
                isDenied = true
                return
            }
            session.addInput(input)
        } catch {
            Debug.log("camera: input failed \(error)")
            session.commitConfiguration()
            previewView?.apply(shape: shape, mirrored: mirrored, deviceName: T("摄像头打开失败"), denied: true)
            onUnavailable?(TF("摄像头打开失败：%@", error.localizedDescription))
            isDenied = true
            return
        }
        session.commitConfiguration()

        // 按实际画面比例定矩形高度
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if dims.width > 0, dims.height > 0 {
            cameraAspect = CGFloat(dims.width) / CGFloat(dims.height)
            applyAppearance()
        }

        self.session = session
        currentDeviceID = device.uniqueID
        previewView?.attach(session: session)
        observeSession(session)
        isCameraRunning = true
        Debug.log("camera: session starting device=\(device.localizedName) visible=\(panel?.isVisible ?? false)")
        sessionQueue.async { session.startRunning() }
        Debug.log("camera: started \(device.localizedName) \(dims.width)x\(dims.height)")
    }

    private func restartSession() {
        guard isVisible else { return }
        startSession()
    }

    private func stopCamera() {
        guard let session else { return }
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers = []
        previewView?.detach()
        self.session = nil
        currentDeviceID = nil
        isCameraRunning = false
        sessionQueue.async { session.stopRunning() }
    }

    /// 拔掉设备、会话被打断、媒体服务重启后都要能自己回来
    private func observeSession(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let device = note.object as? AVCaptureDevice,
                      device.uniqueID == self.currentDeviceID else { return }
                Task { @MainActor in
                    Debug.log("camera: device disconnected")
                    self.currentDeviceID = nil
                    self.startSession()
                }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isCameraRunning = false }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeSession(session) }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
                let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code
                Task { @MainActor in
                    Debug.log("camera: runtime error \(code ?? -1)")
                    self?.isCameraRunning = false
                    // AVErrorMediaServicesWereReset
                    if code == -11819 { self?.restartSession() }
                }
            },
        ]
    }

    private func resumeSession(_ session: AVCaptureSession) {
        guard isVisible else { return }
        sessionQueue.async { [weak self] in
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in self?.isCameraRunning = session.isRunning }
        }
    }
}

// MARK: - 气泡内容视图

/// 摄像头的预览层 + 形状遮罩 + 关闭按钮 + 拖动
final class CameraPreviewView: NSView {
    var onClose: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onResized: ((CGFloat) -> Void)?
    var onMenu: (() -> NSMenu?)?

    /// 四个角都能拖着改大小，保持画面比例
    private enum Corner { case bottomLeft, bottomRight, topLeft, topRight }
    private var activeCorner: Corner?
    private var resizeStartFrame: NSRect = .zero
    private var resizeStartMouse: NSPoint = .zero
    private let grabInset: CGFloat = 18

    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let placeholder = NSView()
    private let placeholderIcon = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var shape: CameraBubble.Shape = .rectangle
    private var needsPlaceholder = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.masksToBounds = true

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)

        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(placeholder)

        placeholderIcon.image = NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)
        placeholderIcon.contentTintColor = .white.withAlphaComponent(0.75)
        placeholderIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        placeholder.addSubview(placeholderIcon)

        placeholderLabel.stringValue = ""
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .white.withAlphaComponent(0.8)
        placeholderLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholder.addSubview(placeholderLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: T("关闭画中画"))
        closeButton.setButtonType(.momentaryChange)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        closeButton.alphaValue = 0.85
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        let shapeRadius = shape.cornerRadius(for: bounds.size)
        layer?.cornerRadius = shapeRadius
        previewLayer.cornerRadius = shapeRadius
        previewLayer.masksToBounds = true
        placeholder.frame = bounds
        placeholder.layer?.cornerRadius = shapeRadius
        let iconSize: CGFloat = 24
        placeholderIcon.frame = NSRect(x: (bounds.width - iconSize) / 2,
                                       y: bounds.midY + 2, width: iconSize, height: iconSize)
        placeholderLabel.frame = NSRect(x: 8, y: bounds.midY - 26, width: bounds.width - 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 24, y: bounds.height - 24, width: 18, height: 18)
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    func apply(shape: CameraBubble.Shape, mirrored: Bool, deviceName: String, denied: Bool) {
        self.shape = shape
        placeholderLabel.stringValue = deviceName
        needsPlaceholder = !denied && previewLayer.session == nil
        placeholder.isHidden = !denied && previewLayer.session != nil
        placeholderIcon.image = NSImage(systemSymbolName: denied ? "video.slash" : "camera",
                                        accessibilityDescription: nil)
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        placeholder.isHidden = true
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        needsLayout = true
    }

    func detach() {
        previewLayer.session = nil
        placeholder.isHidden = false
        placeholderIcon.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
    }

    @objc private func closeClicked() { onClose?() }

    override var acceptsFirstResponder: Bool { false }

    /// 气泡在别人 App 前台时也要能一次点中（拖动 / 关闭都不用先点一下激活）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !closeButton.isHidden, closeButton.frame.insetBy(dx: -4, dy: -4).contains(point) { return closeButton }
        return self
    }

    private func corner(at point: NSPoint) -> Corner? {
        let nearLeft = point.x <= grabInset
        let nearRight = point.x >= bounds.width - grabInset
        let nearBottom = point.y <= grabInset
        let nearTop = point.y >= bounds.height - grabInset
        if nearLeft, nearBottom { return .bottomLeft }
        if nearRight, nearBottom { return .bottomRight }
        if nearLeft, nearTop { return .topLeft }
        if nearRight, nearTop { return .topRight }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        let size = grabInset
        let corners = [
            NSRect(x: 0, y: 0, width: size, height: size),
            NSRect(x: bounds.width - size, y: 0, width: size, height: size),
            NSRect(x: 0, y: bounds.height - size, width: size, height: size),
            NSRect(x: bounds.width - size, y: bounds.height - size, width: size, height: size),
        ]
        for rect in corners { addCursorRect(rect, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let corner = corner(at: point), let window {
            activeCorner = corner
            resizeStartFrame = window.frame
            resizeStartMouse = NSEvent.mouseLocation
            return
        }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation

        if let corner = activeCorner {
            let dx = current.x - resizeStartMouse.x
            let ratio = resizeStartFrame.height > 0 ? resizeStartFrame.height / resizeStartFrame.width : 9.0 / 16.0
            let growsRight = corner == .bottomRight || corner == .topRight
            var width = resizeStartFrame.width + (growsRight ? dx : -dx)
            let screen = window.screen ?? NSScreen.main
            let maxWidth = max(200, (screen?.visibleFrame.width ?? 1440) * 0.55)
            width = min(max(width, 120), maxWidth)
            let height = width * ratio

            var frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
            let isLeft = corner == .bottomLeft || corner == .topLeft
            let isBottom = corner == .bottomLeft || corner == .bottomRight
            frame.origin.x = isLeft ? resizeStartFrame.maxX - width : resizeStartFrame.minX
            frame.origin.y = isBottom ? resizeStartFrame.maxY - height : resizeStartFrame.minY
            window.setFrame(frame, display: true)
            return
        }

        guard let start = dragStartOrigin, let down = dragStartMouse else { return }
        var frame = window.frame
        frame.origin = NSPoint(x: start.x + (current.x - down.x), y: start.y + (current.y - down.y))
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        }
        window.setFrameOrigin(frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if activeCorner != nil {
            activeCorner = nil
            onResized?(window?.frame.width ?? bounds.width)
            return
        }
        dragStartMouse = nil
        dragStartOrigin = nil
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = onMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
}
