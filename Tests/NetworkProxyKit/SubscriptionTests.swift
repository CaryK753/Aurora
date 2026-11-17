import XCTest
@testable import NetworkProxyKit

final class SubscriptionTests: XCTestCase {
    func testClashAliasesNamesRulesAndUnsafeSections() throws {
        let yaml = """
        port: 7890
        proxies:
          - &base
            name: Node
            type: ss
            server: example.com
            port: 443
            cipher: aes-128-gcm
            password: secret
          - <<: *base
            name: Node
          - name: chain
            type: socks5
            server: localhost
            port: 1
            dialer-proxy: Node
        proxy-groups: [{name: Auto, type: select, proxies: [Node]}]
        rules: [DOMAIN-SUFFIX,example.com,DIRECT]
        proxy-providers: {}
        script: {code: never_execute}
        """
        let result = try SubscriptionParser.parse(Data(yaml.utf8))
        XCTAssertEqual(result.nodes.map(\.name), ["Node", "Node (2)"])
        XCTAssertEqual(result.format, "Clash")
        XCTAssertEqual(result.warnings.count, 4)
        XCTAssertEqual(try result.nodes[1].dictionary()["password"] as? String, "secret")
    }

    func testShadowrocketBase64AndCredentials() throws {
        let auth = Data("aes-128-gcm:p@ss:word".utf8).base64EncodedString()
        let links = "ss://\(auth)@example.com:443#Test%20SS\ntrojan://secret@example.org:443?sni=edge.example.org#Trojan"
        let encoded = Data(links.utf8).base64EncodedString()
        let parsed = try SubscriptionParser.parse(Data(encoded.utf8))
        XCTAssertEqual(parsed.nodes.count, 2)
        XCTAssertEqual(parsed.nodes[0].name, "Test SS")
        XCTAssertEqual(try parsed.nodes[0].dictionary()["password"] as? String, "p@ss:word")
        XCTAssertEqual(try parsed.nodes[1].dictionary()["sni"] as? String, "edge.example.org")
    }

    func testLegacySSAndSSR() throws {
        let ss = Data("aes-128-gcm:p@ss:# /word@example.com:8388".utf8).base64EncodedString()
        let password = Data("pass".utf8).base64EncodedString()
        let ssr = Data("example.com:443:auth_sha1_v4:aes-128-cfb:tls1.2_ticket_auth:\(password)".utf8).base64EncodedString()
        let parsed = try SubscriptionParser.parse(Data("ss://\(ss)#Legacy\nssr://\(ssr)".utf8))
        XCTAssertEqual(parsed.nodes.map(\.kind), ["ss", "ssr"])
        XCTAssertEqual(try parsed.nodes[0].dictionary()["password"] as? String, "p@ss:# /word")
    }

    func testVMessVLESSAndHysteria() throws {
        let vmess: [String: Any] = ["v": "2", "ps": "VM", "add": "example.com", "port": "443", "id": "00000000-0000-0000-0000-000000000001", "net": "ws", "path": "/ws", "host": "edge.example.com", "tls": "tls"]
        let encoded = try JSONSerialization.data(withJSONObject: vmess).base64EncodedString()
        let text = "vmess://\(encoded)\nvless://uuid@example.com:443?security=reality&pbk=public&sid=short&type=grpc&serviceName=svc#VL\nhy2://password@example.com:443?sni=edge.example.com#HY"
        let parsed = try SubscriptionParser.parse(Data(text.utf8))
        XCTAssertEqual(parsed.nodes.map(\.kind), ["vmess", "vless", "hysteria2"])
        XCTAssertEqual(try parsed.nodes[0].dictionary()["network"] as? String, "ws")
        XCTAssertEqual(try parsed.nodes[1].dictionary()["grpc-opts"] as? [String: String], ["grpc-service-name": "svc"])
        XCTAssertEqual(try parsed.nodes[2].dictionary()["sni"] as? String, "edge.example.com")
    }

    func testShadowrocketConfiguration() throws {
        let text = """
        [General]
        bypass-system = true
        [Proxy]
        SS = ss, example.com, 443, encrypt-method=aes-128-gcm, password=secret
        Office = socks5, localhost, 1080, username=user, password=pass
        [Rule]
        FINAL,DIRECT
        """
        let parsed = try SubscriptionParser.parse(Data(text.utf8))
        XCTAssertEqual(parsed.nodes.map(\.kind), ["ss", "socks5"])
        XCTAssertEqual(try parsed.nodes[1].dictionary()["username"] as? String, "user")
        XCTAssertFalse(parsed.warnings.isEmpty)
    }

    func testSSPluginTrailingSeparator() throws {
        let auth = Data("aes-128-gcm:pass".utf8).base64EncodedString()
        let node = try SubscriptionParser.parse(Data("ss://\(auth)@example.com:443?plugin=obfs-local%3Bobfs%3Dtls%3B#Plugin".utf8)).nodes[0]
        let config = try node.dictionary()
        XCTAssertEqual(config["plugin"] as? String, "obfs")
        XCTAssertEqual((config["plugin-opts"] as? [String: String])?["mode"], "tls")
    }

    func testAliasExpansionIsBounded() throws {
        var yaml = "base: &a [a,a,a,a,a,a,a,a,a,a]\n"
        var previous = "a"
        for index in 0..<8 {
            let current = "alias\(index)"
            yaml += "\(current): &\(current) [" + Array(repeating: "*\(previous)", count: 10).joined(separator: ",") + "]\n"
            previous = current
        }
        yaml += "proxies: []"
        XCTAssertThrowsError(try SubscriptionParser.parse(Data(yaml.utf8)))
    }

    func testInvalidAndUnsupportedNeverEchoSecrets() throws {
        for text in ["<html>secret</html>", "proxies: []", "unsupported://secret@example.com:123"] {
            XCTAssertThrowsError(try SubscriptionParser.parse(Data(text.utf8))) {
                XCTAssertFalse($0.localizedDescription.contains("secret"))
            }
        }
        let result = try SubscriptionParser.parse(Data("socks5://localhost:1080#Good\ninvalid://secret".utf8))
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertFalse(result.warnings[0].contains("secret"))
        XCTAssertThrowsError(try SubscriptionParser.parse(Data(repeating: 65, count: 5 * 1024 * 1024 + 1)))
    }
}
