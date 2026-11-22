//  ProxyControllerClient.swift
//  Aurora — 通过本机 Unix socket 跟 mihomo 的控制器说话
//
//  为什么不用 127.0.0.1:端口：控制口能读到全部连接与日志（含域名、进程），
//  开在 TCP 端口上等于局域网内任何进程都能读；socket 放在 0700 的目录里，
//  只有本用户能连，也不需要 secret。
//  这里手写 HTTP/1.1：一次性请求读到 EOF，SSE 请求保持连接按行推送。

import Darwin
import Foundation

public final class ProxyControllerClient {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - 一次性请求

    public func get(_ path: String, timeout: TimeInterval = 5) async throws -> Data {
        try await request("GET", path, body: nil, timeout: timeout)
    }

    public func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 5) async throws -> Data {
        let socketPath = self.socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let fd = try Self.openSocket(path: socketPath, timeout: timeout)
                    defer { close(fd) }
                    var request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\n"
                    if let body {
                        request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
                    }
                    request += "\r\n"
                    try Self.write(fd, Data(request.utf8))
                    if let body { try Self.write(fd, body) }
                    let raw = try Self.readToEnd(fd)
                    let response = try Self.parse(raw)
                    if response.status >= 400, !response.body.isEmpty {
                        let text = String(decoding: response.body, as: UTF8.self)
                        throw ProxyFailure(Self.readable(text) ?? "控制器返回 \(response.status)")
                    }
                    continuation.resume(returning: response.body)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 流（SSE）

    public final class Stream {
        private let lock = NSLock()
        private var fd: Int32
        private var cancelled = false
        /// 连接被对端关掉或读失败时回调（取消不算）。上层用它决定要不要重连。
        public var onClose: (() -> Void)?
        init(fd: Int32) { self.fd = fd }
        public func cancel() {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return }
            cancelled = true
            close(fd)
            fd = -1
        }
        fileprivate var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }

    public func stream(_ path: String, onLine: @escaping (String) -> Void) throws -> Stream {
        let fd = try Self.openSocket(path: socketPath, timeout: 0)
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"
        try Self.write(fd, Data(request.utf8))
        let stream = Stream(fd: fd)
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            var lineBuffer = ProxyLineBuffer()
            var headerParsed = false
            var chunked = false
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                pending.append(buffer, count: count)
                if !headerParsed {
                    guard let range = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                    let header = String(decoding: pending[pending.startIndex..<range.lowerBound], as: UTF8.self).lowercased()
                    chunked = header.contains("transfer-encoding: chunked")
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                    headerParsed = true
                }
                var body = Data()
                if chunked {
                    // 逐块解出载荷，不完整的块留在 pending 里等下次。
                    while let next = Self.takeChunk(&pending) { body.append(next) }
                } else {
                    body = pending
                    pending = Data()
                }
                guard !body.isEmpty else { continue }
                for line in lineBuffer.append(body) where !line.isEmpty {
                    let payload = ProxyLineBuffer.payload(fromLine: line) ?? (line.hasPrefix("{") ? line : nil)
                    if let payload { onLine(payload) }
                }
            }
            let cancelled = stream.isCancelled
            stream.cancel()
            if !cancelled { stream.onClose?() }
        }
        return stream
    }

    // MARK: - socket 细节

    private static func openSocket(path: String, timeout: TimeInterval) throws -> Int32 {
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else { throw ProxyFailure("控制器 socket 路径过长") }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyFailure("无法创建控制器连接") }
        if timeout > 0 {
            var value = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard result == 0 else {
            close(fd)
            throw ProxyFailure("控制器未就绪")
        }
        return fd
    }

    private static func write(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let count = send(fd, base.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else { throw ProxyFailure("控制器写入失败") }
                sent += count
            }
        }
    }

    private static func readToEnd(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw ProxyFailure("控制器读取超时") }
            data.append(buffer, count: count)
            if data.count > 8 << 20 { throw ProxyFailure("控制器响应过大") }
        }
        return data
    }

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    static func parse(_ raw: Data) throws -> Response {
        guard let range = raw.range(of: Data("\r\n\r\n".utf8)) else { throw ProxyFailure("控制器响应无法解析") }
        let headerText = String(decoding: raw[raw.startIndex..<range.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ProxyFailure("控制器响应无法解析") }
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            headers[line[..<index].lowercased()] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(raw[range.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = decodeChunks(body)
        } else if let text = headers["content-length"], let length = Int(text), body.count > length {
            body = Data(body.prefix(length))
        }
        return Response(status: status, headers: headers, body: body)
    }

    private static func decodeChunks(_ data: Data) -> Data {
        var pending = data
        var out = Data()
        while let chunk = takeChunk(&pending) { out.append(chunk) }
        return out
    }

    /// 从缓冲里取一个完整的 chunk；不完整就返回 nil 并保留原样。
    private static func takeChunk(_ data: inout Data) -> Data? {
        guard let lineEnd = data.range(of: Data("\r\n".utf8)) else { return nil }
        let header = String(decoding: data[data.startIndex..<lineEnd.lowerBound], as: UTF8.self)
        let sizeText = header.split(separator: ";").first.map(String.init) ?? ""
        guard let size = Int(sizeText, radix: 16) else {
            data.removeSubrange(data.startIndex..<lineEnd.upperBound)
            return nil
        }
        let payloadStart = lineEnd.upperBound
        if size == 0 {
            data.removeSubrange(data.startIndex..<payloadStart)
            return nil
        }
        guard data.distance(from: payloadStart, to: data.endIndex) >= size + 2 else { return nil }
        let payloadEnd = data.index(payloadStart, offsetBy: size)
        let chunk = Data(data[payloadStart..<payloadEnd])
        let removeEnd = data.index(payloadEnd, offsetBy: 2)
        data.removeSubrange(data.startIndex..<removeEnd)
        return chunk
    }

    private static func readable(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["message"] as? String
    }
}
