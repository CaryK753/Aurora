//  TCPRelay.swift
//  AuroraTunnel — 把一条已被接管的 TCP 流接到 SOCKS5 或 HTTP CONNECT

import Foundation
import Network
import NetworkExtension

extension NEAppProxyFlow {
    /// Swift 导入把 closeReadWithError: / closeWriteWithError: 藏掉了，按选择子调用。
    func endRead(_ error: NSError? = nil) {
        perform(NSSelectorFromString("closeReadWithError:"), with: error)
    }

    func endWrite(_ error: NSError? = nil) {
        perform(NSSelectorFromString("closeWriteWithError:"), with: error)
    }
}

final class TCPRelay {
    let id = UUID()
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var phase: Phase
    private var buffer = Data()
    private var closed = false
    private let request: Data
    var onClose: ((UUID) -> Void)?

    private enum Phase {
        case greet
        case reply
        case http
        case pipe
    }

    /// proxyKind 为 socks5 或 http。host/port 是流量真正要去的目标。
    init?(flow: NEAppProxyTCPFlow, host: String, port: Int, proxyHost: String, proxyPort: Int, proxyKind: String) {
        guard let remotePort = NWEndpoint.Port(rawValue: UInt16(proxyPort)),
              let payload = Self.request(kind: proxyKind, host: host, port: port) else { return nil }
        self.flow = flow
        self.request = payload
        self.phase = proxyKind == "http" ? .http : .greet
        queue = DispatchQueue(label: "com.cary.aurora.tunnel.relay")
        connection = NWConnection(
            host: NWEndpoint.Host(proxyHost),
            port: remotePort,
            using: .tcp
        )
    }

    func start() {
        flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self else { return }
            self.queue.async { [self] in
                if error != nil {
                    self.finishOnQueue()
                    return
                }
                self.connection.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.sendHandshake()
                        case .failed, .cancelled:
                            self.finishOnQueue()
                        default:
                            break
                        }
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func close() {
        queue.async { [weak self] in self?.finishOnQueue() }
    }

    private func sendHandshake() {
        let bytes: Data
        if phase == .http {
            bytes = request
        } else {
            bytes = Data([0x05, 0x01, 0x00])
        }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if error != nil {
                    self.finishOnQueue()
                } else {
                    self.readHandshake()
                }
            }
        })
    }

    private func readHandshake() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                if error != nil {
                    self.finishOnQueue()
                    return
                }
                switch self.consume() {
                case .needMore:
                    if isComplete { self.finishOnQueue() } else { self.readHandshake() }
                case .waiting:
                    break
                case .ready:
                    self.pump()
                case .failed:
                    self.finishOnQueue()
                }
            }
        }
    }

    private enum Handshake {
        case needMore
        case waiting
        case ready
        case failed
    }

    private func consume() -> Handshake {
        switch phase {
        case .greet:
            guard buffer.count >= 2 else { return .needMore }
            guard buffer[0] == 0x05, buffer[1] == 0x00 else { return .failed }
            buffer.removeFirst(2)
            phase = .reply
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                self?.queue.async {
                    guard let self else { return }
                    if error != nil { self.finishOnQueue() } else { self.readHandshake() }
                }
            })
            return .waiting
        case .reply:
            return consumeSocksReply()
        case .http:
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .needMore }
            let head = buffer[..<range.lowerBound]
            guard let text = String(data: head, encoding: .utf8), text.contains(" 200 ") else { return .failed }
            buffer.removeSubrange(..<range.upperBound)
            phase = .pipe
            return .ready
        case .pipe:
            return .ready
        }
    }

    private func consumeSocksReply() -> Handshake {
        guard buffer.count >= 5, buffer[0] == 0x05, buffer[1] == 0x00 else {
            return buffer.count >= 2 ? .failed : .needMore
        }
        let atyp = buffer[3]
        let length: Int
        switch atyp {
        case 0x01: length = 10
        case 0x04: length = 22
        case 0x03:
            let name = Int(buffer[4])
            length = 5 + name + 2
        default:
            return .failed
        }
        guard buffer.count >= length else { return .needMore }
        buffer.removeFirst(length)
        phase = .pipe
        return .ready
    }

    private func pump() {
        if !buffer.isEmpty {
            let pending = buffer
            buffer.removeAll()
            flow.write(pending, withCompletionHandler: { [weak self] error in
                self?.queue.async {
                    guard let self else { return }
                    if error != nil { self.finishOnQueue() } else { self.readBoth() }
                }
            })
        } else {
            readBoth()
        }
    }

    private func readBoth() {
        readFromFlow()
        readFromConnection()
    }

    private func readFromFlow() {
        flow.readData { [weak self] data, error in
            self?.queue.async {
                guard let self, !self.closed else { return }
                if error != nil {
                    self.finishOnQueue()
                    return
                }
                guard let data, !data.isEmpty else {
                    self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    self?.queue.async {
                        guard let self else { return }
                        if error != nil { self.finishOnQueue() } else { self.readFromFlow() }
                    }
                })
            }
        }
    }

    private func readFromConnection() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, !self.closed else { return }
                if error != nil {
                    self.finishOnQueue()
                    return
                }
                guard let data, !data.isEmpty else {
                    if isComplete { self.flow.endWrite() }
                    return
                }
                self.flow.write(data, withCompletionHandler: { [weak self] error in
                    self?.queue.async {
                        guard let self else { return }
                        if error != nil || isComplete { self.finishOnQueue() } else { self.readFromConnection() }
                    }
                })
            }
        }
    }

    private func finishOnQueue() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        flow.endRead()
        flow.endWrite()
        onClose?(id)
    }

    private static func request(kind: String, host: String, port: Int) -> Data? {
        guard (1...65535).contains(port), !host.isEmpty else { return nil }
        if kind == "http" {
            let text = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\nProxy-Connection: keep-alive\r\n\r\n"
            return Data(text.utf8)
        }
        var data = Data([0x05, 0x01, 0x00])
        if let ipv4 = ipv4Bytes(host) {
            data.append(0x01)
            data.append(contentsOf: ipv4)
        } else if let ipv6 = ipv6Bytes(host) {
            data.append(0x04)
            data.append(contentsOf: ipv6)
        } else {
            let bytes = Array(host.utf8)
            guard !bytes.isEmpty, bytes.count < 256 else { return nil }
            data.append(0x03)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(UInt8((port >> 8) & 0xFF))
        data.append(UInt8(port & 0xFF))
        return data
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        guard let value = ProxyRuleEngine.ipv4(host) else { return nil }
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.contains(":"), inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}
