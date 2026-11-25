import AVFoundation
import CoreMediaIO

/// AVFoundation exposes a trusted iPhone or iPad screen as an external muxed input.
/// A Continuity Camera is a video input and is intentionally absent from this list.
final class USBDeviceRecording: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    static func devices() -> [AVCaptureDevice] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var enabled: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, 4, &enabled)
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    private let queue = DispatchQueue(label: "aurora.usb.recording")
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var starting: CheckedContinuation<Void, Error>?
    private var ended = false
    private var disconnectObserver: NSObjectProtocol?
    private let onFinish: @MainActor (URL, Error?) -> Void

    init(onFinish: @escaping @MainActor (URL, Error?) -> Void) {
        self.onFinish = onFinish
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Aurora.USB", code: 1, userInfo: [NSLocalizedDescriptionKey: T(message)])
    }

    func start(id: String, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.starting = continuation
                do {
                    guard let device = Self.devices().first(where: { $0.uniqueID == id }) else {
                        throw Self.failure("设备已断开，请通过 USB 连接、解锁并信任此 Mac")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw Self.failure("无法读取设备画面") }
                    self.session.addInput(input)
                    guard self.session.canAddOutput(self.output) else { throw Self.failure("无法创建移动设备录像") }
                    self.session.addOutput(self.output)
                    self.disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                                                                     object: device, queue: nil) { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard !self.ended else { return }
                            if self.output.isRecording {
                                self.output.stopRecording()
                            } else if self.starting != nil {
                                self.finish(url, error: Self.failure("设备已断开，请通过 USB 连接、解锁并信任此 Mac"))
                            }
                        }
                    }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw Self.failure("设备未能启动录制，请检查连接和授权") }
                    self.output.startRecording(to: url, recordingDelegate: self)
                    self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self, self.starting != nil else { return }
                        self.finish(url, error: Self.failure("设备没有返回画面，请解锁设备并确认信任"))
                    }
                } catch {
                    self.finish(url, error: error)
                }
            }
        }
    }

    func stop() { queue.async { self.output.stopRecording() } }
    func pause(_ paused: Bool) {
        queue.async {
            if paused { self.output.pauseRecording() } else { self.output.resumeRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            self.starting?.resume()
            self.starting = nil
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { self.finish(url, error: error) }
    }

    private func finish(_ url: URL, error: Error?) {
        guard !ended else { return }
        ended = true
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
            self.disconnectObserver = nil
        }
        if session.isRunning { session.stopRunning() }
        if let starting {
            self.starting = nil
            try? FileManager.default.removeItem(at: url)
            starting.resume(throwing: error ?? Self.failure("设备没有返回画面"))
        } else {
            Task { @MainActor in onFinish(url, error) }
        }
    }
}
