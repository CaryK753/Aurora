//  PrivateSymbols.swift
//  Aurora — 私有 API 解析层（DisplayServices / IOAVService / CGS）
//  思路来自 MonitorControl（Arm64DDC.swift / IntelDDC.swift），改为运行时 dlsym，免桥接头文件。

import Foundation
import CoreGraphics
import IOKit

enum PrivateSymbols {
    static let displayServices: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    static let coreGraphics: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)

    static let ioKit: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

// MARK: - DisplayServices（内置屏亮度）

typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias GetLinearBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetLinearBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

enum DisplayServicesShim {
    static let getBrightness = PrivateSymbols.load(PrivateSymbols.displayServices, "DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    static let setBrightness = PrivateSymbols.load(PrivateSymbols.displayServices, "DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    static let getLinearBrightness = PrivateSymbols.load(PrivateSymbols.displayServices, "DisplayServicesGetLinearBrightness", as: GetLinearBrightnessFn.self)
    static let setLinearBrightness = PrivateSymbols.load(PrivateSymbols.displayServices, "DisplayServicesSetLinearBrightness", as: SetLinearBrightnessFn.self)

    static var isAvailable: Bool { getBrightness != nil && setBrightness != nil }

    static func brightness(of id: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func setBrightness(_ value: Float, of id: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        return setBrightness(id, value) == 0
    }
}

// MARK: - IOAVService（外接屏 DDC/CI）

typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias IOAVServiceReadI2CFn = @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
typealias IOAVServiceWriteI2CFn = @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
typealias CGSServiceForDisplayNumberFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<io_service_t>) -> Void

enum IOAVShim {
    static let createWithService = PrivateSymbols.load(PrivateSymbols.ioKit, "IOAVServiceCreateWithService", as: IOAVServiceCreateWithServiceFn.self)
    static let readI2C = PrivateSymbols.load(PrivateSymbols.ioKit, "IOAVServiceReadI2C", as: IOAVServiceReadI2CFn.self)
    static let writeI2C = PrivateSymbols.load(PrivateSymbols.ioKit, "IOAVServiceWriteI2C", as: IOAVServiceWriteI2CFn.self)
    static let cgsService = PrivateSymbols.load(PrivateSymbols.coreGraphics, "CGSServiceForDisplayNumber", as: CGSServiceForDisplayNumberFn.self)

    static var isAvailable: Bool { createWithService != nil && readI2C != nil && writeI2C != nil }

    /// 从 IORegistry 里取外接屏的 DCPAVServiceProxy。
    /// macOS 26 上 CGSServiceForDisplayNumber 对外接屏返回 0，只能自己枚举节点。
    static func externalServices() -> [CFTypeRef] {
        guard let create = createWithService else { return [] }
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [(unit: Int, service: CFTypeRef)] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard (property("Location", of: entry) as? String) == "External" else { continue }
            let unit = (property("Unit", of: entry) as? NSNumber)?.intValue ?? 0
            guard let unmanaged = create(kCFAllocatorDefault, entry) else { continue }
            found.append((unit, unmanaged.takeRetainedValue()))
        }
        return found.sorted { $0.unit < $1.unit }.map(\.service)
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// 外接屏 → DDC 通道的统一发现入口
enum DDCChannels {
    static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    static func discover() -> [CGDirectDisplayID: DDCChannel] {
        let displays = externalDisplayIDs()
        guard !displays.isEmpty, IOAVShim.isAvailable else { return [:] }
        var result: [CGDirectDisplayID: DDCChannel] = [:]

        // 1) CGS 直连：老系统上一步到位，macOS 26 上通常返回 0
        if let cgs = IOAVShim.cgsService, let create = IOAVShim.createWithService {
            for id in displays {
                var service: io_service_t = 0
                cgs(id, &service)
                guard service != 0 else { continue }
                defer { IOObjectRelease(service) }
                guard let unmanaged = create(kCFAllocatorDefault, service) else { continue }
                if let channel = DDCChannel(service: unmanaged.takeRetainedValue()), channel.isResponsive {
                    result[id] = channel
                }
            }
        }
        if result.count == displays.count { return result }

        // 2) IORegistry 兜底：按 Unit 顺序把 External 代理配给还没拿到通道的外接屏
        var remaining = displays.filter { result[$0] == nil }
        for service in IOAVShim.externalServices() where !remaining.isEmpty {
            guard let channel = DDCChannel(service: service), channel.isResponsive else { continue }
            result[remaining.removeFirst()] = channel
        }
        return result
    }
}

/// 基于 Apple Silicon 的 DDC/CI 通道（参考 MonitorControl 的 Arm64DDC 实现）
final class DDCChannel {
    private let chipAddress: UInt32 = 0x37      // 7bit address
    private let dataAddress: UInt32 = 0x51
    private let service: CFTypeRef

    /// 通道是否真的能通信：拿亮度（0x10）探一次，读不到就当没有 DDC
    var isResponsive: Bool { read(0x10) != nil }

    init?(service: CFTypeRef?) {
        guard let service else { return nil }
        self.service = service
    }

    /// DDC 校验和：闭区间 [0, end]，与 MonitorControl 的 `start...end` 一致。
    /// 之前写成 0..<end，少算最后一个字节，读回的校验永远对不上 → 整条通道被判成不可用。
    func checksum(_ seed: UInt8, _ bytes: [UInt8], upTo end: Int) -> UInt8 {
        guard end >= 0, end < bytes.count else { return seed }
        var value = seed
        for index in 0...end { value ^= bytes[index] }
        return value
    }

    private func transfer(send: [UInt8], replyLength: Int) -> [UInt8]? {
        guard let write = IOAVShim.writeI2C, let read = IOAVShim.readI2C else { return nil }

        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let seed: UInt8 = send.count == 1 ? UInt8(chipAddress << 1) : UInt8((chipAddress << 1) ^ dataAddress)
        packet[packet.count - 1] = checksum(seed, packet, upTo: packet.count - 2)

        var reply = [UInt8](repeating: 0, count: replyLength)
        var success = false

        for _ in 0..<5 {
            usleep(10_000)
            for _ in 0..<2 {
                let status = packet.withUnsafeMutableBytes { buffer -> IOReturn in
                    write(service, chipAddress, dataAddress, buffer.baseAddress!, UInt32(buffer.count))
                }
                success = status == 0
            }
            if replyLength > 0 {
                usleep(50_000)
                let status = reply.withUnsafeMutableBytes { buffer -> IOReturn in
                    read(service, chipAddress, 0, buffer.baseAddress!, UInt32(buffer.count))
                }
                if status == 0 {
                    success = checksum(0x50, reply, upTo: reply.count - 2) == reply[reply.count - 1]
                }
            }
            if success { return reply }
            usleep(20_000)
        }
        return nil
    }

    func read(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let reply = transfer(send: [vcp], replyLength: 11), reply.count >= 10 else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0 else { return nil }
        return (current, max)
    }

    @discardableResult
    func write(_ vcp: UInt8, value: UInt16) -> Bool {
        transfer(send: [vcp, UInt8(value >> 8), UInt8(value & 0xFF)], replyLength: 0) != nil
    }
}
