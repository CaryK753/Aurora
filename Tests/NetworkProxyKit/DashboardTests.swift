import XCTest
@testable import NetworkProxyKit

final class DashboardTests: XCTestCase {

    // MARK: - 配置迁移

    func testLegacySingleSubscriptionMigratesIntoList() throws {
        let legacy = Data(#"""
        {"settings":{"source":"subscription","subscriptionURL":"https://sub.example.com/clash?token=x",
        "selectedNode":"Node","mode":"rule","localPort":17890,"bypassLAN":true,"bypassMainland":false,
        "fallbackDirect":false,"useSubscriptionRules":true,"customRules":"","dnsServers":"1.1.1.1",
        "ipv6":true,"refreshMainlandOnStart":true,"subscriptionRefreshHours":6},
        "subscription":{"nodes":[{"name":"Node","configuration":""}],
        "rules":["DOMAIN-SUFFIX,example.com,Group"],"warnings":[],"format":"clash"}}
        """#.utf8)
        let profile = try JSONDecoder().decode(ProxyProfile.self, from: legacy)
        XCTAssertEqual(profile.subscriptions.count, 1)
        let subscription = try XCTUnwrap(profile.activeSubscription)
        XCTAssertEqual(subscription.name, "sub.example.com")
        XCTAssertEqual(subscription.url, "https://sub.example.com/clash?token=x")
        XCTAssertEqual(subscription.refreshHours, 6)
        XCTAssertEqual(subscription.nodes.count, 1)
        XCTAssertEqual(profile.subscription.rules, ["DOMAIN-SUFFIX,example.com,Group"])
    }

    func testSettingsDecodeKeepsDefaultsForMissingKeys() throws {
        let data = Data(#"{"settings":{"mode":"global"},"subscriptions":[]}"#.utf8)
        let profile = try JSONDecoder().decode(ProxyProfile.self, from: data)
        XCTAssertEqual(profile.settings.mode, .global)
        XCTAssertEqual(profile.settings.localPort, 17890)
        XCTAssertEqual(profile.settings.groupType, .select)
        XCTAssertEqual(profile.settings.testURL, "https://www.gstatic.com/generate_204")
        XCTAssertTrue(profile.settings.routeTailscale)
        XCTAssertEqual(profile.settings.ruleSets, [])
    }

    func testProfileRoundTripKeepsMultipleSubscriptions() throws {
        var profile = ProxyProfile()
        let first = SubscriptionProfile(name: "A", url: "https://a.example.com/sub",
                                        nodes: [try node("N1")], rules: [], format: "clash")
        let second = SubscriptionProfile(name: "B", url: "https://b.example.com/sub",
                                         nodes: [try node("N2"), try node("N3")], rules: [], format: "clash")
        profile.subscriptions = [first, second]
        profile.activeSubscriptionID = second.id
        let data = try JSONEncoder().encode(profile)
        let loaded = try JSONDecoder().decode(ProxyProfile.self, from: data)
        XCTAssertEqual(loaded.subscriptions.map(\.name), ["A", "B"])
        XCTAssertEqual(loaded.activeSubscription?.name, "B")
        XCTAssertEqual(loaded.allNodes.map(\.name), ["N1", "N2", "N3"])
    }

    // MARK: - 配置生成

    func testAutoGroupAndAllNodesAreWritten() throws {
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        settings.groupType = .urlTest
        settings.healthCheckSeconds = 600
        settings.tolerance = 80
        let subscription = ProxySubscription(nodes: [try node("N1"), try node("N2")])
        let config = try object(settings, subscription, controllerSocket: "/tmp/aurora.sock")

        XCTAssertEqual(config["external-controller-unix"] as? String, "/tmp/aurora.sock")
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 2)
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["type"] as? String, "url-test")
        XCTAssertEqual(groups.first?["url"] as? String, settings.testURL)
        XCTAssertEqual(groups.first?["interval"] as? Int, 600)
        XCTAssertEqual(groups.first?["tolerance"] as? Int, 80)
        XCTAssertEqual(groups.first?["proxies"] as? [String], ["N1", "N2"])
    }

    func testStatusEntriesNeverJoinTheGroup() throws {
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        let quota = try ProxyNode(["name": "剩余流量：10 GB", "type": "http", "server": "example.com", "port": 8080])
        let config = try object(settings, ProxySubscription(nodes: [quota, try node("N1")]))
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["proxies"] as? [String], ["N1"])
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 2)
    }

    func testRuleSetsBecomeProvidersAndRulesInOrder() throws {
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        settings.useSubscriptionRules = false
        settings.ruleSets = [
            ProxyRuleSet(name: "广告", url: "https://rules.example.com/ad.yaml", behavior: .domain, intervalHours: 12),
            ProxyRuleSet(name: "公司网", url: "https://rules.example.com/corp.yaml", behavior: .classical, direct: true)
        ]
        settings.customRules = "DOMAIN-SUFFIX,corp.example.com,TAILSCALE"
        let config = try object(settings, ProxySubscription(nodes: [try node("N1")]), tailscalePort: 21080)
        let providers = try XCTUnwrap(config["rule-providers"] as? [String: Any])
        XCTAssertNotNil(providers["aurora-广告"])
        XCTAssertNotNil(providers["aurora-公司网"])
        let rules = try XCTUnwrap(config["rules"] as? [String])
        XCTAssertEqual(rules.first, "DOMAIN-SUFFIX,corp.example.com,TAILSCALE")
        XCTAssertTrue(rules.contains("RULE-SET,aurora-广告,AURORA"))
        XCTAssertTrue(rules.contains("RULE-SET,aurora-公司网,DIRECT"))
        XCTAssertEqual(rules.last, "MATCH,AURORA")
        let govIndex = try XCTUnwrap(rules.firstIndex(of: "DOMAIN-SUFFIX,gov.cn,DIRECT"))
        let adIndex = try XCTUnwrap(rules.firstIndex(of: "RULE-SET,aurora-广告,AURORA"))
        XCTAssertLessThan(govIndex, adIndex)
        XCTAssertLessThan(adIndex, rules.count - 1)
    }

    func testTailscaleOutletAddsProxyAndRules() throws {
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        settings.tailscaleDomains = "*.internal.example, nas.example"
        let config = try object(settings, ProxySubscription(nodes: [try node("N1")]), tailscalePort: 21080)
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        let tailscale = proxies.first { $0["name"] as? String == ProxyConfiguration.tailscaleName }
        XCTAssertEqual(tailscale?["type"] as? String, "socks5")
        XCTAssertEqual(tailscale?["port"] as? Int, 21080)
        let rules = try XCTUnwrap(config["rules"] as? [String])
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,ts.net,TAILSCALE"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,internal.example,TAILSCALE"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,nas.example,TAILSCALE"))
    }

    func testTailscaleRuleRejectedWithoutOutlet() throws {
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        settings.customRules = "DOMAIN-SUFFIX,corp.example.com,TAILSCALE"
        XCTAssertThrowsError(try object(settings, ProxySubscription(nodes: [try node("N1")])))
    }

    func testDuplicateRuleSetNamesAndBadHealthCheckFail() throws {
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        let set = ProxyRuleSet(name: "ad", url: "https://rules.example.com/ad.yaml")
        settings.ruleSets = [set, ProxyRuleSet(name: "AD", url: "https://rules.example.com/ad2.yaml")]
        XCTAssertThrowsError(try object(settings, ProxySubscription(nodes: [try node("N1")])))
        settings.ruleSets = []
        settings.healthCheckSeconds = 10
        XCTAssertThrowsError(try object(settings, ProxySubscription(nodes: [try node("N1")])))
    }

    // MARK: - 规则测试

    func testRuleTesterReportsMatchAndSkippedRules() throws {
        var settings = ProxySettings()
        settings.customRules = "DST-PORT,25,REJECT\nPROCESS-NAME,Foo,DIRECT"
        settings.groupType = .select
        let plan = try ProxyRulePlanner.plan(settings: settings,
                                             subscription: ProxySubscription(rules: ["DOMAIN-SUFFIX,example.com,Group"]))
        let hit = ProxyRuleTester.test(host: "www.example.com", port: 443, plan: plan)
        XCTAssertEqual(hit.match?.origin, .subscription)
        XCTAssertEqual(hit.policy, "AURORA")
        XCTAssertTrue(hit.skipped.contains { $0.rule.type == "PROCESS-NAME" })

        let rejected = ProxyRuleTester.test(host: "mail.example.org", port: 25, plan: plan)
        XCTAssertEqual(rejected.match?.origin, .custom)
        XCTAssertEqual(rejected.policy, "REJECT")

        let mainland = ProxyRuleTester.test(host: "baidu.com", port: 443, plan: plan)
        XCTAssertEqual(mainland.match?.origin, .fallback)
        XCTAssertEqual(mainland.policy, "AURORA")
    }

    // MARK: - 控制器数据

    func testTrafficAndConnectionDecoding() throws {
        let traffic = try ProxyControllerPayload.traffic(Data(#"{"up":1024,"down":20480,"upTotal":12345678,"downTotal":987654321}"#.utf8))
        XCTAssertEqual(traffic.up, 1024)
        XCTAssertEqual(traffic.downTotal, 987654321)

        let json = #"""
        {"downloadTotal":987654321,"uploadTotal":12345678,"memory":45678901,"connections":[
        {"id":"a1","metadata":{"network":"tcp","type":"HTTP","sourceIP":"192.168.1.2","destinationIP":"142.250.72.14",
        "sourcePort":"54321","destinationPort":443,"host":"www.google.com","processPath":"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"},
        "upload":4096,"download":65536,"start":"2026-07-18T10:30:00.123456+08:00",
        "chains":["N1","AURORA"],"rule":"DomainSuffix","rulePayload":"google.com"}]}
        """#
        let snapshot = try ProxyControllerPayload.connections(Data(json.utf8))
        let connection = try XCTUnwrap(snapshot.connections.first)
        XCTAssertEqual(connection.target, "www.google.com")
        XCTAssertEqual(connection.destinationPort, "443")
        XCTAssertEqual(connection.policy, "N1")
        XCTAssertEqual(connection.ruleDescription, "DomainSuffix(google.com)")
        XCTAssertEqual(connection.processName, "Google Chrome")
        XCTAssertNotNil(connection.start)
        XCTAssertEqual(snapshot.memory, 45678901)
    }

    func testProxyRulesAndLogDecoding() throws {
        let proxies = try ProxyControllerPayload.proxies(Data(#"""
        {"proxies":{"AURORA":{"name":"AURORA","type":"URLTest","now":"N2","all":["N1","N2"],
        "history":[{"time":"2026-07-18T10:00:00Z","delay":120}]},"N1":{"name":"N1","type":"Shadowsocks","alive":true}}}
        """#.utf8))
        XCTAssertEqual(proxies["AURORA"]?.now, "N2")
        XCTAssertEqual(proxies["AURORA"]?.lastDelay, 120)
        XCTAssertTrue(proxies["AURORA"]?.isGroup == true)
        XCTAssertFalse(proxies["N1"]?.isGroup == true)

        let rules = try ProxyControllerPayload.rules(Data(#"""
        {"rules":[{"index":0,"type":"DomainSuffix","payload":"google.com","proxy":"AURORA","size":-1,"extra":{"hitCount":42}}]}
        """#.utf8))
        XCTAssertEqual(rules.first?.hitCount, 42)

        let line = try ProxyControllerPayload.logLine(Data(#"{"type":"warning","payload":"[TCP] timeout"}"#.utf8))
        XCTAssertEqual(line?.level, "warning")
        XCTAssertEqual(line?.message, "[TCP] timeout")
    }

    func testLineBufferSplitsCleanlyAndStripsSSEPrefix() {
        var buffer = ProxyLineBuffer()
        XCTAssertEqual(buffer.append(Data("data: {\"up\":1".utf8)), [])
        let lines = buffer.append(Data("}\ndata: {\"up\":2}\n\n".utf8))
        XCTAssertEqual(lines.compactMap(ProxyLineBuffer.payload(fromLine:)), ["{\"up\":1}", "{\"up\":2}"])
        XCTAssertNil(ProxyLineBuffer.payload(fromLine: ": ping"))
        XCTAssertNil(ProxyLineBuffer.payload(fromLine: "event: message"))
    }

    /// 有真实内核时校验生成的配置：AURORA_MIHOMO=/path/to/mihomo swift test --filter generatedConfig
    func testGeneratedConfigPassesEngineCheck() throws {
        guard let engine = ProcessInfo.processInfo.environment["AURORA_MIHOMO"] else {
            throw XCTSkip("no engine")
        }
        var settings = ProxySettings()
        settings.selectedNode = "N1"
        settings.bypassMainland = false
        settings.groupType = .urlTest
        settings.customRules = "DOMAIN-SUFFIX,corp.example.com,TAILSCALE"
        settings.tailscaleDomains = "nas.example.com"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try ProxyConfiguration.generate(
            settings: settings,
            subscription: ProxySubscription(nodes: [try node("N1"), try node("N2")]),
            mainlandFile: nil,
            controllerSocket: directory.appendingPathComponent("ctl.sock").path,
            tailscalePort: 21080
        )
        let config = directory.appendingPathComponent("config.json")
        try data.write(to: config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: engine)
        process.arguments = ["-t", "-d", directory.path, "-f", config.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    // MARK: - 辅助

    private func node(_ name: String) throws -> ProxyNode {
        try ProxyNode(["name": name, "type": "http", "server": "127.0.0.1", "port": 18080])
    }

    private func object(_ settings: ProxySettings, _ subscription: ProxySubscription,
                        controllerSocket: String? = nil, tailscalePort: Int? = nil) throws -> [String: Any] {
        let data = try ProxyConfiguration.generate(settings: settings, subscription: subscription,
                                                   mainlandFile: nil, controllerSocket: controllerSocket,
                                                   tailscalePort: tailscalePort)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
