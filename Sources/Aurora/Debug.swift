//  Debug.swift
//  Aurora — 轻量日志（便于在打包运行后排查问题）

import Foundation

enum Debug {
    private static let url = URL(fileURLWithPath: "/tmp/aurora-debug.log")

    static func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["AURORA_DEBUG"] != "0" else { return }
        let line = "[\(Self.timeString())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
