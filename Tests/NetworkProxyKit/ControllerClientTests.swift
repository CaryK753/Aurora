import Darwin
import Foundation
import XCTest
@testable import NetworkProxyKit

/// 用一条真实的 Unix socket 验证控制器的 HTTP / SSE 解析，避免只靠 mock 字符串。
final class ControllerClientTests: XCTestCase {
    private var server: FakeUnixServer?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testGetParsesChunkedAndPlainBodies() async throws {
        let path = NSTemporaryDirectory() + "aurora-ctl-\(UUID().uuidString).sock"
        let server = try FakeUnixServer(path: path)
        self.server = server
        server.handler = { request in
            if request.hasPrefix("DELETE") {
                return FakeUnixServer.Response(status: 204, body: Data(), chunked: false)
            }
            let body = Data(#"{"downloadTotal":10,"uploadTotal":2,"memory":64,"connections":[]}"#.utf8)
            return FakeUnixServer.Response(status: 200, body: body, chunked: false)
        }
        let client = ProxyControllerClient(socketPath: path)
        let data = try await client.get("/connections")
        let snapshot = try ProxyControllerPayload.connections(data)
        XCTAssertEqual(snapshot.downloadTotal, 10)
        XCTAssertEqual(snapshot.memory, 64)

        let empty = try await client.request("DELETE", "/connections/abc")
        XCTAssertTrue(empty.isEmpty)
    }

    func testServerErrorSurfacesMessage() async throws {
        let path = NSTemporaryDirectory() + "aurora-ctl-\(UUID().uuidString).sock"
        let server = try FakeUnixServer(path: path)
        self.server = server
        server.handler = { _ in
            FakeUnixServer.Response(status: 400,
                                    body: Data(#"{"message":"unsupported proxy type"}"#.utf8),
                                    chunked: false)
        }
        let client = ProxyControllerClient(socketPath: path)
        do {
            _ = try await client.get("/proxies")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? ProxyFailure)?.message, "unsupported proxy type")
        }
    }

    /// 有真实内核时手动跑：AURORA_CONTROLLER_SOCKET=/path/to/ctl.sock swift test --filter realEngine
    func testRealEngineSmoke() async throws {
        guard let path = ProcessInfo.processInfo.environment["AURORA_CONTROLLER_SOCKET"] else {
            throw XCTSkip("no real engine")
        }
        let client = ProxyControllerClient(socketPath: path)
        let proxies = try ProxyControllerPayload.proxies(try await client.get("/proxies"))
        XCTAssertFalse(proxies.isEmpty)
        let snapshot = try ProxyControllerPayload.connections(try await client.get("/connections"))
        XCTAssertEqual(snapshot.connections.count, 0)

        let expectation = expectation(description: "one traffic sample")
        let stream = try client.stream("/traffic") { payload in
            guard let data = payload.data(using: .utf8),
                  (try? ProxyControllerPayload.traffic(data)) != nil else { return }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 6)
        stream.cancel()
    }

    func testStreamSplitsSSEDataLines() async throws {
        let path = NSTemporaryDirectory() + "aurora-ctl-\(UUID().uuidString).sock"
        let server = try FakeUnixServer(path: path)
        self.server = server
        server.streamBody = """
        data: {"up":1,"down":2,"upTotal":3,"downTotal":4}

        data: {"up":5,"down":6,"upTotal":7,"downTotal":8}


        """
        let client = ProxyControllerClient(socketPath: path)
        let expectation = expectation(description: "two samples")
        var samples: [ProxyTrafficSample] = []
        let gate = DispatchQueue(label: "controller-test-samples")
        let stream = try client.stream("/traffic") { payload in
            guard let data = payload.data(using: .utf8),
                  let sample = try? ProxyControllerPayload.traffic(data) else { return }
            let done = gate.sync { () -> Bool in
                samples.append(sample)
                return samples.count >= 2
            }
            if done { expectation.fulfill() }
        }
        await fulfillment(of: [expectation], timeout: 5)
        stream.cancel()
        let result = gate.sync { samples }
        XCTAssertEqual(result.map(\.up), [1, 5])
        XCTAssertEqual(result.last?.downTotal, 8)
    }
}

/// 只支持一个连接的极简 UDS HTTP 服务端，够用来验证客户端。
final class FakeUnixServer {
    struct Response {
        var status: Int
        var body: Data
        var chunked: Bool
    }

    private let path: String
    private var fd: Int32 = -1
    private var connection: Int32 = -1
    private let queue = DispatchQueue(label: "fake-unix-server")
    var handler: (String) -> Response = { _ in Response(status: 204, body: Data(), chunked: false) }
    /// 非空时按 chunked SSE 推一次然后关闭。
    var streamBody: String?

    init(path: String) throws {
        self.path = path
        unlink(path)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else { throw ProxyFailure("socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyFailure("socket 创建失败") }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw ProxyFailure("socket 监听失败")
        }
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while fd >= 0 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            connection = client
            serve(client)
            close(client)
            connection = -1
        }
    }

    private func serve(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var request = Data()
        while !request.contains(Data("\r\n\r\n".utf8)) {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(buffer, count: count)
        }
        let text = String(decoding: request, as: UTF8.self)
        if let body = streamBody {
            var response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            let payload = Data(body.utf8)
            response += String(payload.count, radix: 16) + "\r\n" + body + "\r\n"
            response += "0\r\n\r\n"
            _ = response.withCString { send(client, $0, strlen($0), 0) }
        } else {
            let result = handler(text)
            var response = "HTTP/1.1 \(result.status) \(result.status == 204 ? "No Content" : "OK")\r\n"
            response += "Content-Type: application/json\r\nContent-Length: \(result.body.count)\r\nConnection: close\r\n\r\n"
            _ = response.withCString { send(client, $0, strlen($0), 0) }
            if !result.body.isEmpty {
                _ = result.body.withUnsafeBytes { send(client, $0.baseAddress, result.body.count, 0) }
            }
        }
    }

    func stop() {
        if connection >= 0 { close(connection); connection = -1 }
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    deinit { stop() }
}
