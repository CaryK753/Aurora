//  NetworkService.swift
//  Aurora — 网络细节：VPN 状态、按进程流量（nettop）、上下行测速

import AppKit
import Combine
import Foundation

struct AppTraffic: Identifiable, Equatable {
    let id: pid_t
    var name: String
    var download: Double   // bytes / s
    var upload: Double
}

struct VPNStatus: Equatable {
    var connected: Bool = false
    var name: String?
    var interface: String?

    var summary: String? {
        guard connected else { return nil }
        return name ?? interface ?? "VPN"
    }
}

/// 用 nettop 采按进程网络流量；只在「网络」指标被选中时运行，避免常驻开销
@MainActor
final class NetworkProcessSampler: ObservableObject {
    @Published private(set) var items: [AppTraffic] = []

    private var timer: Timer?
    private var isSampling = false

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            sample()
            timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.sample() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            items = []
        }
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Self.capture()
            Task { @MainActor in
                guard let self else { return }
                self.items = rows
                self.isSampling = false
            }
        }
    }

    private nonisolated static func capture() -> [AppTraffic] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-x", "-L", "1", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }

        // nettop -L 1 需要大约一秒才输出这一帧，稍等再读，避免管道阻塞
        let deadline = Date().addingTimeInterval(1.6)
        while process.isRunning, Date() < deadline {
            usleep(80_000)
        }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var traffic: [pid_t: AppTraffic] = [:]

        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let label = String(fields[0])
            guard let dot = label.lastIndex(of: ".") else { continue }
            let name = String(label[label.startIndex..<dot])
            guard let pid = pid_t(label[label.index(after: dot)...]) else { continue }
            guard let down = Double(fields[1]), let up = Double(fields[2]) else { continue }
            if down <= 0 && up <= 0 { continue }
            if let existing = traffic[pid] {
                traffic[pid] = AppTraffic(id: pid, name: existing.name, download: existing.download + down, upload: existing.upload + up)
            } else {
                traffic[pid] = AppTraffic(id: pid, name: name, download: down, upload: up)
            }
        }

        return traffic.values.sorted { $0.download + $0.upload > $1.download + $1.upload }
    }
}

/// 上下行测速：Cloudflare 的公开测速端点，不传任何本机信息
@MainActor
final class SpeedTester: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var lastRun: Date?
    @Published private(set) var error: String?

    private let downloadURL = "https://speed.cloudflare.com/__down?bytes=25000000"
    private let uploadURL = "https://speed.cloudflare.com/__up"

    func run() {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        downloadMbps = nil
        uploadMbps = nil
        lastRun = Date()

        Task {
            var config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)

            do {
                if let url = URL(string: downloadURL) {
                    var request = URLRequest(url: url)
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    let start = Date()
                    let (data, _) = try await session.data(for: request)
                    let elapsed = max(Date().timeIntervalSince(start), 0.05)
                    downloadMbps = Double(data.count) * 8 / elapsed / 1_000_000
                }

                if let url = URL(string: uploadURL) {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    let payload = Data(repeating: 0x41, count: 8 * 1024 * 1024)
                    let start = Date()
                    _ = try await session.upload(for: request, from: payload)
                    let elapsed = max(Date().timeIntervalSince(start), 0.05)
                    uploadMbps = Double(payload.count) * 8 / elapsed / 1_000_000
                }
            } catch {
                self.error = error.localizedDescription
            }

            isRunning = false
        }
    }
}

enum VPNProbe {
    private nonisolated(unsafe) static var cached = VPNStatus()
    private nonisolated(unsafe) static var cachedAt = Date.distantPast

    /// 带缓存：Overview 每秒重绘，不能每次都 fork scutil
    static func current(maxAge: TimeInterval = 15) -> VPNStatus {
        if Date().timeIntervalSince(cachedAt) < maxAge { return cached }
        let fresh = probe()
        cached = fresh
        cachedAt = Date()
        return fresh
    }

    /// 同时看系统 VPN 配置状态和 utun 隧道，避免漏掉第三方客户端
    private static func probe() -> VPNStatus {
        var status = VPNStatus()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                guard line.contains("(Connected)") else { continue }
                // 形如：* (Connected)      ABCDEFGH-... VPN (com.vendor.protocol)
                if let range = line.range(of: "\\(Connected\\)") {
                    let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    let parts = tail.split(separator: " ")
                    if parts.count > 1 {
                        status.connected = true
                        status.name = String(parts[1])
                    }
                }
            }
        }

        if !status.connected, let tunnel = activeTunnel() {
            status.connected = true
            status.interface = tunnel
            status.name = "VPN · \(tunnel)"
        }
        return status
    }

    private static func activeTunnel() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer = ifaddr
        var candidates: [String] = []

        while let current = pointer {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("utun"), let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                candidates.append(name)
            }
            pointer = interface.ifa_next
        }
        // utun0-3 常被系统用于 Handoff / Private Relay，不作为 VPN 证据
        return candidates.first { name in
            guard let index = Int(name.dropFirst(4)) else { return false }
            return index >= 4
        }
    }
}
