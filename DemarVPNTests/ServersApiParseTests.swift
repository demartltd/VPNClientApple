import XCTest
@testable import DemarVPN

final class ServersApiParseTests: XCTestCase {
    func testParseHysteria2WithAlpnAndObfs() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "hysteria2",
                    "server": "fi.example.com",
                    "server_port": 8443,
                    "password": "secret",
                    "tls": [
                        "server_name": "sni.example.com",
                        "alpn": ["h3", "h2"],
                    ],
                    "obfs": ["type": "salamander", "password": "obfs-pass"],
                    "city": "Helsinki",
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let item: [String: Any] = [
            "id": "srv-1",
            "name": "FI-FREE-2",
            "city": "FallbackCity",
            "protocol": "hysteria2",
            "clientConfigJson": configJSON,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.id, "srv-1")
        XCTAssertEqual(profile.displayName, "FI-FREE-2")
        XCTAssertEqual(profile.city, "Helsinki")
        XCTAssertEqual(profile.tier, .free)
        XCTAssertEqual(profile.profile.server, "fi.example.com")
        XCTAssertEqual(profile.profile.port, 8443)
        XCTAssertEqual(profile.profile.password, "secret")
        XCTAssertEqual(profile.profile.tlsServerName, "sni.example.com")
        XCTAssertEqual(profile.profile.alpn, ["h3", "h2"])
        XCTAssertEqual(profile.profile.obfsPassword, "obfs-pass")
    }

    func testSkipUnsupportedProtocol() {
        let item: [String: Any] = [
            "id": "x",
            "name": "XX-FREE-1",
            "protocol": "wireguard",
            "clientConfigJson": "{}",
        ]
        XCTAssertNil(ServersApi.parseServerItem(item))
    }

    func testDefaultAlpnWhenMissing() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "hysteria2",
                    "server": "nl.example.com",
                    "server_port": 443,
                    "password": "p",
                    "tls": ["server_name": "nl.example.com"],
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let item: [String: Any] = [
            "id": "srv-2",
            "name": "NL-PLUS-1",
            "city": "Amsterdam",
            "protocol": "hysteria2",
            "clientConfigJson": configJSON,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.profile.alpn, ["h3"])
        XCTAssertNil(profile.profile.obfsPassword)
        XCTAssertEqual(profile.tier, .plus)
        XCTAssertEqual(profile.city, "Amsterdam")
    }

    func testParseHysteria2WithoutPassword() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "hysteria2",
                    "server": "de.example.com",
                    "server_port": 443,
                    "tls": ["server_name": "de.example.com"],
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let item: [String: Any] = [
            "id": "srv-demo",
            "name": "DE-FREE-1",
            "city": "Berlin",
            "protocol": "hysteria2",
            "clientConfigJson": configJSON,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.profile.password, "")
        XCTAssertFalse(profile.canConnect)
        XCTAssertEqual(profile.tier, .free)
    }

    func testParsePreviewServerWithoutConfig() throws {
        let item: [String: Any] = [
            "id": "6a3eeae01afeb82f6b1cddb7",
            "name": "DE-FREE-93",
            "status": "free",
            "protocol": "hysteria2",
            "city": "Frankfurt am Main",
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.id, "6a3eeae01afeb82f6b1cddb7")
        XCTAssertEqual(profile.displayName, "DE-FREE-93")
        XCTAssertEqual(profile.city, "Frankfurt am Main")
        XCTAssertFalse(profile.canConnect)
    }

    func testTesterTierVisible() {
        let tester = ServerProfile(
            hysteria2: Hysteria2Profile(
                displayName: "FI-TESTER-1",
                server: "a.example.com",
                port: 1,
                password: "p",
                tlsServerName: "a.example.com"
            ),
            id: "t1"
        )
        let free = ServerProfile(
            hysteria2: Hysteria2Profile(
                displayName: "FI-FREE-1",
                server: "b.example.com",
                port: 1,
                password: "p",
                tlsServerName: "b.example.com"
            ),
            id: "f1"
        )
        let tiers = [tester, free].visibleTiers()
        XCTAssertTrue(tiers.contains(.tester))
        XCTAssertTrue(tiers.contains(.free))
        XCTAssertFalse(tiers.contains(.dev))
    }

    func testConnectPlanIncludesObfs() throws {
        let profile = Hysteria2Profile(
            displayName: "FI-FREE-1",
            server: "fi.example.com",
            port: 8443,
            password: "secret",
            tlsServerName: "sni.example.com",
            alpn: ["h3"],
            obfsPassword: "obfs"
        )
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(profile))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        let obfs = try XCTUnwrap(proxy["obfs"] as? [String: Any])
        XCTAssertEqual(obfs["type"] as? String, "salamander")
        XCTAssertEqual(obfs["password"] as? String, "obfs")
        let tls = try XCTUnwrap(proxy["tls"] as? [String: Any])
        XCTAssertEqual(tls["alpn"] as? [String], ["h3"])
    }
}
