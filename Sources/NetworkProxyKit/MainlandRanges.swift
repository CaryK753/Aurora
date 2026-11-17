import Foundation
import Darwin
import Yams

public enum MainlandRanges {
    public static let sourceURL = URL(string: "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest")!

    /// APNIC 的 CN 分配归属，不把 HK / MO / TW 合并进大陆。
    public static func parse(_ text: String) throws -> [String] {
        var ranges = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 7, fields[0] == "apnic", fields[1] == "CN",
                  ["allocated", "assigned"].contains(fields[6]) else { continue }
            if fields[2] == "ipv4" {
                guard let start = ipv4(fields[3]), let count = UInt64(fields[4]), count > 0,
                      UInt64(start) + count <= UInt64(UInt32.max) + 1 else { throw ProxyFailure("大陆 IPv4 数据无效") }
                var cursor = UInt64(start)
                var remaining = count
                while remaining > 0 {
                    let alignment = cursor == 0 ? 32 : min(cursor.trailingZeroBitCount, 32)
                    let available = 63 - remaining.leadingZeroBitCount
                    let bits = min(alignment, available)
                    let address = UInt32(cursor)
                    let ip = "\(address >> 24).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
                    ranges.insert("\(ip)/\(32 - bits)")
                    let block = UInt64(1) << bits
                    cursor += block; remaining -= block
                }
            } else if fields[2] == "ipv6" {
                var address = in6_addr()
                guard let prefix = Int(fields[4]), (0...128).contains(prefix),
                      inet_pton(AF_INET6, fields[3], &address) == 1 else { throw ProxyFailure("大陆 IPv6 数据无效") }
                ranges.insert("\(fields[3])/\(prefix)")
            }
        }
        guard !ranges.isEmpty else { throw ProxyFailure("未找到大陆 IP 地址数据") }
        return ranges.sorted()
    }

    public static func providerData(_ ranges: [String]) throws -> Data {
        // 内核的 rule-provider 读取器要求实际 YAML 的 payload 字段，不接受 JSON 根对象。
        Data(try Yams.dump(object: ["payload": ranges]).utf8)
    }

    private static func ipv4(_ string: String) -> UInt32? {
        let bytes = string.split(separator: ".", omittingEmptySubsequences: false)
        guard bytes.count == 4 else { return nil }
        var value: UInt32 = 0
        for byte in bytes {
            guard let number = UInt8(byte) else { return nil }
            value = value << 8 | UInt32(number)
        }
        return value
    }
}
