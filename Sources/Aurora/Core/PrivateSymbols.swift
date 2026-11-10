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
}

/// 基于 Apple Silicon 的 DDC/CI 通道（参考 MonitorControl 的 Arm64DDC 实现）
final class DDCChannel {
    private let chipAddress: UInt32 = 0x37      // 7bit address
    private let dataAddress: UInt32 = 0x51
    private let service: CFTypeRef

    static func make(for displayID: CGDirectDisplayID) -> DDCChannel? {
        guard IOAVShim.isAvailable, let create = IOAVShim.createWithService, let cgs = IOAVShim.cgsService else { return nil }
        var ioService: io_service_t = 0
        cgs(displayID, &ioService)
        guard ioService != 0 else { return nil }
        defer { IOObjectRelease(ioService) }
        guard let unmanaged = create(kCFAllocatorDefault, ioService) else { return nil }
        return DDCChannel(service: unmanaged.takeRetainedValue())
    }

    private init(service: CFTypeRef) {
        self.service = service
    }

    private func checksum(_ seed: UInt8, _ bytes: [UInt8], upTo end: Int) -> UInt8 {
        var value = seed
        for index in 0..<end { value ^= bytes[index] }
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
