import Foundation
import Network
import NetworkProxyKit

enum ProxyNodeTester {
    static func latency(_ node: ProxyNode, timeout: TimeInterval = 4) async -> Int? {
        guard let endpoint = node.endpoint,
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return nil }
        return await withCheckedContinuation { continuation in
            let started = ContinuousClock.now
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
            let completion = LatencyCompletion(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let duration = started.duration(to: .now)
                    let milliseconds = duration.components.seconds * 1_000
                        + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
                    completion.finish(max(1, Int(milliseconds)))
                case .failed, .cancelled:
                    completion.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.finish(nil)
            }
        }
    }
}

private final class LatencyCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Int?, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<Int?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Int?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: value)
    }
}
