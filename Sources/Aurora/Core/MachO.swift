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
                let subtype = readBigEndian(table, at: base + 4)
                let bytes = Int64(readBigEndian(table, at: base + 12))
                result.append(MachOSlice(architecture: name(for: cpu, subtype: subtype), bytes: bytes))
            }
            return result
        }

        // 瘦二进制：只有一份，字段按本机字节序（小端）
        if magic == 0xFEED_FACF || magic == 0xFEED_FACE {
            let cpu = head.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let subtypeData = try? handle.read(upToCount: 4)
            let subtype = subtypeData?.count == 4 ? readLittleEndian(subtypeData ?? Data(), at: 0) : 0
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return [MachOSlice(architecture: name(for: cpu, subtype: subtype), bytes: bytes)]
        }
        return nil
    }

    /// 当前进程实际在跑的架构。通用二进制里每个切片各自编译，运行到的那一片就是本机。
    static var hostArchitecture: String {
        #if arch(arm64)
        arm64
        #elseif arch(x86_64)
        x86_64
        #else
        arm64
        #endif
    }

    /// 这台 Mac 要留下来的架构。Apple Silicon 同时留 arm64 和 arm64e，只拿掉 Intel。
    static var keptArchitectures: Set<String> {
        #if arch(arm64)
        ["arm64", "arm64e", "arm64_32"]
        #elseif arch(x86_64)
        ["x86_64"]
        #else
        [hostArchitecture]
        #endif
    }

    /// 可以从这份文件里拿掉、而且拿掉后本机还能跑的架构。没有本机架构时返回空，避免把唯一能跑的那份删掉。
    static func removableArchitectures(in slices: [MachOSlice]) -> [String] {
        let present = Set(slices.map(\.architecture))
        guard !present.isDisjoint(with: keptArchitectures) else { return [] }
        return present.subtracting(keptArchitectures).sorted()
    }

    /// 本机用不到的那几份有多大。Apple Silicon 上不把 arm64e 算进去。
    static func wasted(in path: String) -> Int64 {
        guard let slices = slices(at: path) else { return 0 }
        let remove = removableArchitectures(in: slices)
        guard !remove.isEmpty else { return 0 }
        return slices.filter { remove.contains($0.architecture) }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    /// 这份文件里有没有本机用不到、可以拿掉的架构
    static func isUniversal(_ path: String) -> Bool {
        guard let slices = slices(at: path) else { return false }
        return !removableArchitectures(in: slices).isEmpty
    }

    private static func name(for cpu: UInt32, subtype: UInt32) -> String {
        let sub = subtype & 0x00FF_FFFF
        switch cpu {
        case 0x0100_000C: return sub == 2 ? "arm64e" : arm64
        case 0x0200_000C: return "arm64_32"
        case 0x0100_0007: return x86_64
        case 0x0000_0007: return "i386"
        case 0x0000_000C: return "arm"
        default: return String(format: "cpu_%08x", cpu)
        }
    }

    private static func readLittleEndian(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private static func readBigEndian(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).byteSwapped }
    }
}
