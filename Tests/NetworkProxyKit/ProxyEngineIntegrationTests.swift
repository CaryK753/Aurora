import Foundation
import XCTest
@testable import NetworkProxyKit

final class ProxyEngineIntegrationTests: XCTestCase {
    func testImportedProtocolConfigurations() throws {
        guard let core = ProcessInfo.processInfo.environment["AURORA_PROXY_TEST_CORE"] else {
            throw XCTSkip("Set AURORA_PROXY_TEST_CORE to validate imported protocols")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProxyProfileStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uuid = "00000000-0000-0000-0000-000000000001"
        let vmess: [String: Any] = ["ps": "VM", "add": "example.com", "port": 443, "id": uuid, "net": "ws", "tls": "tls"]
        let ss = Data("aes-128-gcm:test-password".utf8).base64EncodedString()
        let vm = try JSONSerialization.data(withJSONObject: vmess).base64EncodedString()
        let links = ["ss://\(ss)@example.com:443?plugin=obfs-local%3Bobfs%3Dtls%3B#SS",
                     "vmess://\(vm)", "vless://\(uuid)@example.com:443?security=tls&type=grpc&serviceName=test#VL",
                     "trojan://test@example.com:443?sni=example.com#TR", "hy2://test@example.com:443?sni=example.com#HY",
                     "tuic://\(uuid):test@example.com:443?sni=example.com#TU"]
        let subscription = try SubscriptionParser.parse(Data(links.joined(separator: "\n").utf8))
        XCTAssertEqual(subscription.nodes.count, 6)
        var settings = ProxySettings()
        settings.mode = .global
        for node in subscription.nodes {
            settings.selectedNode = node.name
            let url = directory.appendingPathComponent("active.json")
            try ProxyProfileStorage.save(ProxyConfiguration.generate(settings: settings, subscription: subscription, mainlandFile: nil), to: url)
            let check = Process()
            check.executableURL = URL(fileURLWithPath: core)
            check.arguments = ["-t", "-d", directory.path, "-f", url.path]
            let output = Pipe()
            check.standardOutput = output; check.standardError = output
            try check.run()
            let diagnostic = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0, node.kind + ": " + diagnostic)
        }
    }

    func testRealEngineRoutingAndAPNIC() async throws {
        guard let core = ProcessInfo.processInfo.environment["AURORA_PROXY_TEST_CORE"] else {
            throw XCTSkip("Set AURORA_PROXY_TEST_CORE to run the local engine integration test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProxyProfileStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portsFile = directory.appendingPathComponent("ports.json")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/servers.py").path, portsFile.path]
        python.standardError = FileHandle.nullDevice
        try python.run()
        defer { FixtureProcess.stop(python) }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: portsFile.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let ports = try JSONSerialization.jsonObject(with: Data(contentsOf: portsFile)) as! [String: Int]
        let node = try ProxyNode(["name": "Mock", "type": "http", "server": "127.0.0.1", "port": ports["upstream"]!])
        let subscription = ProxySubscription(nodes: [node])
        var settings = ProxySettings()
        settings.localPort = ports["proxy"]!
        settings.selectedNode = "Mock"
        settings.ipv6 = false
        settings.bypassLAN = false
        settings.bypassMainland = false
        settings.useSubscriptionRules = false
        let mainland = directory.appendingPathComponent("mainland.yaml")
        try ProxyProfileStorage.save(MainlandRanges.providerData(["127.0.0.1/32"]), to: mainland)
        for scenario in ["global", "direct", "rule-custom", "rule-mainland", "rule-fallback-proxy", "rule-fallback-direct"] {
            settings.mode = scenario == "global" ? .global : scenario == "direct" ? .direct : .rule
            settings.bypassMainland = scenario == "rule-mainland"
            settings.customRules = scenario == "rule-custom" ? "IP-CIDR,127.0.0.1/32,DIRECT" : ""
            settings.fallbackDirect = scenario == "rule-fallback-direct"
            let config = directory.appendingPathComponent("active.json")
            try ProxyProfileStorage.save(ProxyConfiguration.generate(settings: settings, subscription: subscription, mainlandFile: mainland.path), to: config)
            let check = Process()
            check.executableURL = URL(fileURLWithPath: core)
            check.arguments = ["-t", "-d", directory.path, "-f", config.path]
            let checkOutput = Pipe()
            check.standardOutput = checkOutput
            check.standardError = checkOutput
            try check.run()
            let diagnostics = String(decoding: checkOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0, scenario + ": " + diagnostics)
            if check.terminationStatus != 0 { continue }
            let diagnosticsURL = directory.appendingPathComponent("engine.log")
            FileManager.default.createFile(atPath: diagnosticsURL.path, contents: nil)
            let engineOutput = try FileHandle(forWritingTo: diagnosticsURL)
            let engine = Process()
            engine.executableURL = URL(fileURLWithPath: core)
            engine.arguments = ["-d", directory.path, "-f", config.path]
            engine.standardOutput = engineOutput
            engine.standardError = engineOutput
            try engine.run()
            defer { if engine.isRunning { FixtureProcess.stop(engine) } }
            var body = ""
            for _ in 0..<40 {
                let curl = Process()
                let output = Pipe()
                curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curl.arguments = ["--silent", "--show-error", "--max-time", "2", "--noproxy", "", "--proxy", "http://127.0.0.1:\(settings.localPort)", "http://127.0.0.1:\(ports["origin"]!)/test"]
                curl.standardOutput = output
                curl.standardError = FileHandle.nullDevice
                try curl.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                curl.waitUntilExit()
                if curl.terminationStatus == 0 { body = String(decoding: data, as: UTF8.self); break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let expected = ["global", "rule-fallback-proxy"].contains(scenario) ? "PROXY" : "DIRECT"
            try engineOutput.close()
            let engineDiagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
            XCTAssertEqual(body, expected, scenario + ": " + engineDiagnostics)
            FixtureProcess.stop(engine)
        }
        if ProcessInfo.processInfo.environment["AURORA_PROXY_TEST_APNIC"] == "1" {
            let data = try await ProxyHTTPClient.fetch(MainlandRanges.sourceURL, limit: 15 * 1024 * 1024)
            let ranges = try MainlandRanges.parse(String(decoding: data, as: UTF8.self))
            XCTAssertGreaterThan(ranges.count, 1000)
            XCTAssertTrue(ranges.contains(where: { $0.contains(":") }))
            print("APNIC CN ranges validated: \(ranges.count)")
        }
    }
}
