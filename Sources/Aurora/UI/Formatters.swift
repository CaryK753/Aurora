//  Formatters.swift
//  Aurora — 数值格式化

import Foundation

enum Fmt {
    static func percent(_ value: Double, digits: Int = 0) -> String {
        let number = value * 100
        if digits == 0 { return "\(Int(number.rounded()))%" }
        return String(format: "%.\(digits)f%%", number)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func bytes(_ value: Double) -> String {
        bytes(UInt64(max(0, value)))
    }

    static func rate(_ value: Double) -> String {
        if value < 1 { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s"
    }

    static func minutes(_ value: Int) -> String {
        guard value > 0 else { return "—" }
        let hours = value / 60
        let mins = value % 60
        if hours > 0 { return TF("%d 小时 %d 分", hours, mins) }
        return TF("%d 分钟", mins)
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        if days > 0 { return TF("%d 天 %d 小时", days, hours) }
        let minutes = (Int(interval) % 3600) / 60
        return TF("%d 小时 %d 分", hours, minutes)
    }

    static func signedRate(_ value: Double) -> String {
        rate(value)
    }
}

extension Fmt {
    static func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return T("刚刚") }
        if interval < 3600 { return TF("%d 分钟前", Int(interval / 60)) }
        if interval < 86400 { return TF("%d 小时前", Int(interval / 3600)) }
        if interval < 86400 * 7 { return TF("%d 天前", Int(interval / 86400)) }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
