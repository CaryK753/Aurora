import Foundation
import IOKit.hid

/// I/O 在独立 runloop 中接收；请求在串行工作队列等待，绝不阻塞界面线程。
final class LogitechHIDTransport: @unchecked Sendable {
    let device: IOHIDDevice
    let index: UInt8
    private let condition = NSCondition()
    private var expected: [UInt8]?
    private var reply: [UInt8]?
    private var stopped = false
    private var started = false
    private var openResult: IOReturn = kIOReturnNotOpen
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    private var thread: Thread?
    var onNotification: (([UInt8]) -> Void)?

    init(device: IOHIDDevice, index: UInt8 = 0xFF) { self.device = device; self.index = index }
    deinit { input.deallocate() }

    func start() throws {
        thread = Thread { [self] in
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if result == kIOReturnSuccess {
                IOHIDDeviceRegisterInputReportCallback(device, input, 4096, { context, _, _, _, reportID, pointer, count in
                    guard let context, count > 0 else { return }
                    let transport = Unmanaged<LogitechHIDTransport>.fromOpaque(context).takeUnretainedValue()
                    var bytes = Array(UnsafeBufferPointer(start: pointer, count: count))
                    if bytes.first != UInt8(reportID), reportID == 0x10 || reportID == 0x11 { bytes.insert(UInt8(reportID), at: 0) }
                    transport.receive(bytes)
                }, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            }
            condition.lock(); openResult = result; started = true; condition.broadcast(); condition.unlock()
            if result == kIOReturnSuccess {
                while !isStopped { CFRunLoopRunInMode(.defaultMode, 0.1, false) }
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDDeviceRegisterInputReportCallback(device, input, 4096, nil, nil)
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }
        thread?.name = "Aurora Logitech HID"
        thread?.start()
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !started { if !condition.wait(until: deadline) { stopped = true; throw LogitechFailure.timeout } }
        guard openResult == kIOReturnSuccess else {
            stopped = true
            throw LogitechFailure.unavailable("无法打开罗技接口（\(openResult)），请检查输入监控授权和 Options+ 占用")
        }
    }

    var isStopped: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    func close() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock(); thread = nil }

    func request(feature: UInt8, function: UInt8, parameters: [UInt8] = [], deviceIndex: UInt8? = nil, timeout: TimeInterval = 0.8) throws -> [UInt8] {
        let packet = try HIDPPPacket.request(device: deviceIndex ?? index, feature: feature, function: function, parameters: parameters)
        condition.lock()
        guard !stopped, expected == nil else { condition.unlock(); throw LogitechFailure.unavailable("设备已断开或存在未完成的请求") }
        expected = packet; reply = nil
        condition.unlock()
        let result = packet.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(packet[0]), $0.baseAddress!, packet.count) }
        condition.lock()
        defer { expected = nil; reply = nil; condition.unlock() }
        guard result == kIOReturnSuccess else { throw LogitechFailure.unavailable("HID 报告发送失败（\(result)）") }
        let deadline = Date().addingTimeInterval(timeout)
        while reply == nil && !stopped { if !condition.wait(until: deadline) { break } }
        guard let reply else { throw LogitechFailure.timeout }
        return try HIDPPPacket.payload(reply)
    }

    private func receive(_ bytes: [UInt8]) {
        condition.lock()
        if let expected, HIDPPPacket.matches(bytes, request: expected) {
            reply = bytes; condition.broadcast(); condition.unlock(); return
        }
        condition.unlock()
        guard bytes.count >= 7, [0x10, 0x11].contains(bytes[0]), bytes[3] & 0x0F == 0,
              [0, 1, 2, 3, 4, 5, 6, 0xFF].contains(bytes[1]) else { return }
        onNotification?(bytes)
    }
}
