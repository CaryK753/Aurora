import XCTest
@testable import NetworkProxyKit

final class TailscaleTests: XCTestCase {
    func testStatusParsingWithPeersAndExitNode() throws {
        let json = #"""
        {"Version":"1.104.7","BackendState":"Running",
         "Self":{"ID":"n1","HostName":"mac-mini","DNSName":"mac-mini.tailnet.ts.net.","OS":"macOS","TailscaleIPs":["100.64.0.1"]},
         "User":{"LoginName":"me@example.com","DisplayName":"Me"},
         "CurrentTailnet":{"MagicDNSSuffix":"tailnet.ts.net"},
         "ExitNodeStatus":{"ID":"n2","Online":true},
         "Peer":{
           "n3":{"ID":"n3","HostName":"laptop","DNSName":"laptop.tailnet.ts.net.","OS":"macOS","Online":false,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.3"]},
           "n2":{"ID":"n2","HostName":"nas","DNSName":"nas.tailnet.ts.net.","OS":"linux","Online":true,"ExitNode":true,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.2"]}
         }}
        """#
        let snapshot = try TailscaleStatusParser.parse(Data(json.utf8))
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertEqual(snapshot.account, "me@example.com")
        XCTAssertEqual(snapshot.hostName, "mac-mini")
        XCTAssertEqual(snapshot.magicDNSSuffix, "tailnet.ts.net")
        XCTAssertEqual(snapshot.onlinePeers, 1)
        XCTAssertEqual(snapshot.exitNodeName, "nas")
        XCTAssertEqual(snapshot.exitNodes.count, 2)
        // 在线节点排在前面
        XCTAssertEqual(snapshot.peers.map(\.displayName), ["nas", "laptop"])
        XCTAssertEqual(snapshot.peers.first?.ipv4, "100.64.0.2")
    }

    func testNeedsLoginAndEmptyStates() throws {
        let snapshot = try TailscaleStatusParser.parse(Data(#"{"BackendState":"NeedsLogin","Health":["want running"]}"#.utf8))
        XCTAssertTrue(snapshot.needsLogin)
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.stateText, "等待登录")
        XCTAssertEqual(snapshot.health, ["want running"])

        let empty = try TailscaleStatusParser.parse(Data("{}".utf8))
        XCTAssertEqual(empty.backendState, "NoState")
        XCTAssertTrue(empty.peers.isEmpty)
        XCTAssertNil(empty.exitNodeName)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try TailscaleStatusParser.parse(Data("[]".utf8)))
    }
}
