import XCTest
@testable import NetworkProxyKit

final class RoutingTests: XCTestCase {
    func testDefaultImplementationAndRecovery() {
        XCTAssertEqual(NetworkImplementation.preferred(saved: "tunnel", extensionAvailable: false, hasBackup: false), .system)
        XCTAssertEqual(NetworkImplementation.preferred(saved: nil, extensionAvailable: true, hasBackup: false), .tunnel)
        XCTAssertEqual(NetworkImplementation.preferred(saved: "tunnel", extensionAvailable: true, hasBackup: true), .system)
        XCTAssertEqual(NetworkImplementation.preferred(saved: "system", extensionAvailable: true, hasBackup: false), .system)
        XCTAssertEqual(NetworkImplementation.preferred(saved: "tailscale", extensionAvailable: true, hasBackup: false), .tunnel)
    }

    func testSubscriptionStatusEntriesAreNotPreferredNodes() throws {
        let quota = try ProxyNode(["name": "剩余流量：100 GB", "type": "vless", "server": "example.com", "port": 443])
        let expiry = try ProxyNode(["name": "Expiry 2027-01-01", "type": "vless", "server": "example.com", "port": 443])
        let actual = try ProxyNode(["name": "Singapore 01", "type": "vless", "server": "example.com", "port": 443])
        XCTAssertTrue(quota.isLikelyStatusEntry)
        XCTAssertTrue(expiry.isLikelyStatusEntry)
        XCTAssertFalse(actual.isLikelyStatusEntry)
    }

    func testMainlandAddressParsingIPv4IPv6AndNonPowerOfTwo() throws {
        let input = """
        apnic|CN|ipv4|1.0.1.0|256|20200101|allocated
        apnic|CN|ipv4|1.0.2.0|768|20200101|allocated
        apnic|CN|ipv6|2400:3200::|32|20200101|assigned
        apnic|HK|ipv4|2.0.0.0|256|20200101|allocated
        apnic|TW|ipv4|3.0.0.0|256|20200101|allocated
        apnic|CN|ipv4|4.0.0.0|256|20200101|available
        """
        XCTAssertEqual(try MainlandRanges.parse(input), ["1.0.1.0/24", "1.0.2.0/23", "1.0.4.0/24", "2400:3200::/32"])
        XCTAssertThrowsError(try MainlandRanges.parse("apnic|CN|ipv4|300.0.0.0|256|0|allocated"))
        XCTAssertThrowsError(try MainlandRanges.parse(""))
    }

    func testRulePrecedenceAndSubscriptionNormalization() throws {
        var settings = ProxySettings()
        settings.selectedNode = "Node"
        settings.customRules = "DOMAIN,custom.example,PROXY\nDOMAIN-SUFFIX,local,REJECT"
        let subscription = try fixture()
        let data = try ProxyConfiguration.generate(settings: settings, subscription: subscription, mainlandFile: "/tmp/cn.yaml")
        let config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rules = config["rules"] as! [String]
        XCTAssertEqual(rules[0], "DOMAIN,custom.example,AURORA")
        XCTAssertEqual(rules[1], "DOMAIN-SUFFIX,local,REJECT")
        XCTAssertLessThan(rules.firstIndex(of: "DOMAIN-SUFFIX,gov.cn,DIRECT")!,
                          rules.firstIndex(of: "DOMAIN-SUFFIX,example.com,AURORA")!)
        XCTAssertLessThan(rules.firstIndex(of: "RULE-SET,aurora-mainland,DIRECT")!, rules.firstIndex(of: "DOMAIN-SUFFIX,example.com,AURORA")!)
        XCTAssertEqual(rules.last, "MATCH,AURORA")
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertNil(config["external-ui"])
        XCTAssertEqual((config["tun"] as? [String: Bool])?["enable"], false)
    }

    func testThreeModesAndFallback() throws {
        var settings = ProxySettings()
        settings.mode = .direct
        var config = try object(settings, ProxySubscription())
        XCTAssertEqual(config["rules"] as? [String], ["MATCH,DIRECT"])
        settings.mode = .global; settings.selectedNode = "Node"
        config = try object(settings, fixture())
        XCTAssertEqual(config["rules"] as? [String], ["MATCH,AURORA"])
        settings.mode = .rule; settings.fallbackDirect = true; settings.bypassMainland = false
        config = try object(settings, fixture())
        XCTAssertEqual((config["rules"] as? [String])?.last, "MATCH,DIRECT")
        settings.localPort = 80
        XCTAssertThrowsError(try object(settings, fixture()))
    }

    func testMissingNodeAddressDBAndBadCustomRulesFail() throws {
        var settings = ProxySettings()
        XCTAssertThrowsError(try object(settings, fixture()))
        settings.selectedNode = "Node"
        XCTAssertThrowsError(try object(settings, fixture()))
        XCTAssertThrowsError(try ProxyRoutingRules.custom("DOMAIN,example.com,UNKNOWN"))
        XCTAssertThrowsError(try ProxyRoutingRules.custom("RULE-SET,untrusted,PROXY"))
        let imported = ProxyRoutingRules.imported(["DOMAIN,example.com,Group", "GEOIP,CN,DIRECT", "GEOSITE,cn,DIRECT", "MATCH,Group"], mainland: true)
        XCTAssertEqual(imported.rules, ["DOMAIN,example.com,AURORA", "RULE-SET,aurora-mainland,DIRECT"])
        XCTAssertEqual(imported.skipped, 2)
    }

    func testProfilePersistencePermissionsAndCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = ProxyProfile()
        profile.subscription = try fixture()
        profile.settings.subscriptionURL = "https://example.com/sub?token=secret"
        let url = directory.appendingPathComponent("profile.json")
        try ProxyProfileStorage.save(profile, to: url)
        let loaded = try ProxyProfileStorage.load(from: url)
        XCTAssertEqual(loaded.settings.subscriptionURL, profile.settings.subscriptionURL)
        XCTAssertEqual(loaded.subscription.nodes, profile.subscription.nodes)
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(fileMode.intValue, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(dirMode.intValue, 0o700)
    }

    func testLegacyProfileWithoutRefreshIntervalStillDecodes() throws {
        let data = Data(#"{"settings":{"source":"manual","subscriptionURL":"","selectedNode":"","mode":"rule","localPort":17890,"bypassLAN":true,"bypassMainland":true,"fallbackDirect":false,"useSubscriptionRules":true,"customRules":"","dnsServers":"","ipv6":true,"refreshMainlandOnStart":true},"subscription":{"nodes":[],"rules":[],"warnings":[],"format":""}}"#.utf8)
        let profile = try JSONDecoder().decode(ProxyProfile.self, from: data)
        XCTAssertNil(profile.settings.subscriptionRefreshHours)
    }

    private func fixture() throws -> ProxySubscription {
        ProxySubscription(nodes: [try ProxyNode(["name": "Node", "type": "http", "server": "127.0.0.1", "port": 18080])],
                          rules: ["DOMAIN-SUFFIX,example.com,Group", "MATCH,DIRECT"])
    }
    private func object(_ settings: ProxySettings, _ subscription: ProxySubscription) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: ProxyConfiguration.generate(settings: settings, subscription: subscription, mainlandFile: nil)) as! [String: Any]
    }
}
