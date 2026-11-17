import Foundation
import XCTest
@testable import NetworkProxyKit

final class DownloadTests: XCTestCase {
    func testDownloadLimitsFailuresAndParsing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProxyProfileStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portsFile = directory.appendingPathComponent("ports.json")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/servers.py").path, portsFile.path]
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { FixtureProcess.stop(server) }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: portsFile.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let ports = try JSONSerialization.jsonObject(with: Data(contentsOf: portsFile)) as! [String: Int]
        let base = "http://127.0.0.1:\(ports["origin"]!)"
        let data = try await ProxyHTTPClient.fetch(URL(string: base + "/subscription")!)
        XCTAssertEqual(try SubscriptionParser.parse(data).nodes.first?.name, "Local")
        for suffix in ["/large?token=secret", "/missing?token=secret"] {
            do {
                _ = try await ProxyHTTPClient.fetch(URL(string: base + suffix)!, limit: 1024)
                XCTFail("Download should have failed")
            } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
        do {
            _ = try await ProxyHTTPClient.fetch(URL(string: "file:///tmp/secret")!)
            XCTFail("Non-HTTP URLs must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
}
