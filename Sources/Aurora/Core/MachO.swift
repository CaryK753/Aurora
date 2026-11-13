//  MachOBinary.swift
//  Aurora — 读取 Mach-O 头，判断一个可执行文件里有哪些 CPU 架构
//
//  「通用二进制」清理只关心两件事：这个文件是不是同时带了 Intel 和 Apple Silicon 两份，
//  以及用不上的那一份有多大。直接读 fat header 比调 `lipo -info` 快得多。

import Foundation

struct MachOSlice: Equatable {
    /// arm64 / x86_64 / arm64e …
    let architecture: String
    let bytes: Int64
}

enum MachOBinary {
    static let arm64 = "arm64"
    static let x86_64 = "x86_64"

    /// 读文件头里的架构表；不是 Mach-O 或读不出来返回 nil
    static func slices(at path: String) -> [MachOSlice]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return nil }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        // fat 头在文件里按大端写：小端机器读出来正好是反的（0xCAFEBABE → 0xBEBAFECA）
        if magic == 0xBEBA_FECA {
            let count = Int(readBigEndian(head, at: 4))
            guard (1...32).contains(count) else { return nil }
            guard let table = try? handle.read(upToCount: count * 20), table.count == count * 20 else { return nil }
            var result: [MachOSlice] = []
            for index in 0..<count {
                let base = index * 20
                // fat_arch: cputype, cpusubtype, offset, size, align（都是大端 4 字节）
                let cpu = readBigEndian(table, at: base)
                let bytes = Int64(readBigEndian(table, at: base + 12))
                result.append(MachOSlice(architecture: name(for: cpu), bytes: bytes))
            }
            return result
        }

        // 瘦二进制：只有一份，字段按本机字节序（小端）
        if magic == 0xFEED_FACF || magic == 0xFEED_FACE {
            let cpu = head.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return [MachOSlice(architecture: name(for: cpu), bytes: bytes)]
        }
        return nil
    }

    /// 用不上的那一份有多大：当前机器是 arm64，所以 Intel 那一份算可回收
    static func wasted(in path: String) -> Int64 {
        guard let slices = slices(at: path),
              slices.contains(where: { $0.architecture == arm64 }),
              let intel = slices.first(where: { $0.architecture == x86_64 }) else { return 0 }
        return intel.bytes
    }

    /// 这份文件同时带了 arm64 和 x86_64 吗
    static func isUniversal(_ path: String) -> Bool {
        guard let slices = slices(at: path) else { return false }
        return slices.contains { $0.architecture == arm64 } && slices.contains { $0.architecture == x86_64 }
    }

    private static func name(for cpu: UInt32) -> String {
        switch cpu {
        case 0x0100_000C: return arm64
        case 0x0200_000C: return "arm64_32"
        case 0x0100_0007: return x86_64
        case 0x0000_0007: return "i386"
        case 0x0000_000C: return "arm"
        default: return String(format: "cpu_%08x", cpu)
        }
    }

    private static func readBigEndian(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).byteSwapped }
    }
}
