import XCTest
@testable import Demar_Proxy

final class ServersApiParseTests: XCTestCase {
    func testValidateParsedCountRejectsEmptyParse() throws {
        XCTAssertThrowsError(try ServersApi.validateParsedCount(rawCount: 3, parsedCount: 0))
        try ServersApi.validateParsedCount(rawCount: 0, parsedCount: 0)
        try ServersApi.validateParsedCount(rawCount: 2, parsedCount: 2)
    }

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
                    "up_mbps": 10,
                    "down_mbps": 10,
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
        XCTAssertEqual(profile.serverProtocol, .hysteria2)
        guard case .hysteria2(let hy2) = profile.profile else {
            return XCTFail("expected hysteria2")
        }
        XCTAssertEqual(hy2.server, "fi.example.com")
        XCTAssertEqual(hy2.port, 8443)
        XCTAssertEqual(hy2.password, "secret")
        XCTAssertEqual(hy2.tlsServerName, "sni.example.com")
        XCTAssertEqual(hy2.alpn, ["h3", "h2"])
        XCTAssertEqual(hy2.obfsPassword, "obfs-pass")
        XCTAssertEqual(hy2.upMbps, 10)
        XCTAssertEqual(hy2.downMbps, 10)
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
        guard case .hysteria2(let hy2) = profile.profile else {
            return XCTFail("expected hysteria2")
        }
        XCTAssertEqual(hy2.alpn, ["h3"])
        XCTAssertNil(hy2.obfsPassword)
        XCTAssertNil(hy2.upMbps)
        XCTAssertNil(hy2.downMbps)
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
        guard case .hysteria2(let hy2) = profile.profile else {
            return XCTFail("expected hysteria2")
        }
        XCTAssertEqual(hy2.password, "")
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

    func testParseTrojan() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "trojan",
                    "server": "tr.example.com",
                    "server_port": 443,
                    "password": "trojan-secret",
                    "tls": ["server_name": "cdn.example.com"],
                    "city": "Helsinki",
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let item: [String: Any] = [
            "id": "tr-1",
            "name": "FI-PLUS-3",
            "protocol": "trojan",
            "clientConfigJson": configJSON,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.serverProtocol, .trojan)
        XCTAssertEqual(profile.city, "Helsinki")
        XCTAssertTrue(profile.canConnect)
        guard case .trojan(let trojan) = profile.profile else {
            return XCTFail("expected trojan")
        }
        XCTAssertEqual(trojan.server, "tr.example.com")
        XCTAssertEqual(trojan.password, "trojan-secret")
        XCTAssertEqual(trojan.tlsServerName, "cdn.example.com")

        let plan = profile.connectPlan
        XCTAssertEqual(plan.proxyOutbound["type"] as? String, "trojan")
        let mux = try XCTUnwrap(plan.proxyOutbound["multiplex"] as? [String: Any])
        XCTAssertEqual(mux["enabled"] as? Bool, true)
        let tls = try XCTUnwrap(plan.proxyOutbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["server_name"] as? String, "cdn.example.com")
        XCTAssertTrue(plan.tun.uplinkDomains.contains("cdn.example.com"))
        XCTAssertTrue(plan.tun.uplinkDomains.contains("tr.example.com"))
    }

    func testParseVlessReality() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "vless",
                    "server": "vl.example.com",
                    "server_port": 443,
                    "uuid": "bf000d23-0752-40b4-affe-68f7707a9661",
                    "flow": "xtls-rprx-vision",
                    "tls": [
                        "server_name": "www.cloudflare.com",
                        "reality": [
                            "public_key": "pub-key",
                            "short_id": "abcd",
                        ],
                    ],
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let item: [String: Any] = [
            "id": "vl-1",
            "name": "DE-VIP-1",
            "city": "Frankfurt",
            "protocol": "vless_reality",
            "clientConfigJson": configJSON,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.serverProtocol, .vlessReality)
        XCTAssertTrue(profile.canConnect)
        guard case .vlessReality(let vless) = profile.profile else {
            return XCTFail("expected vless")
        }
        XCTAssertEqual(vless.uuid, "bf000d23-0752-40b4-affe-68f7707a9661")
        XCTAssertEqual(vless.publicKey, "pub-key")
        XCTAssertEqual(vless.shortId, "abcd")
        XCTAssertEqual(vless.flow, "xtls-rprx-vision")

        let plan = profile.connectPlan
        XCTAssertEqual(plan.proxyOutbound["type"] as? String, "vless")
        XCTAssertEqual(plan.proxyOutbound["flow"] as? String, "xtls-rprx-vision")
        XCTAssertNil(plan.proxyOutbound["network"])
        XCTAssertNil(plan.proxyOutbound["multiplex"])
        let tls = try XCTUnwrap(plan.proxyOutbound["tls"] as? [String: Any])
        let utls = try XCTUnwrap(tls["utls"] as? [String: Any])
        XCTAssertEqual(utls["fingerprint"] as? String, "chrome")
        let reality = try XCTUnwrap(tls["reality"] as? [String: Any])
        XCTAssertEqual(reality["public_key"] as? String, "pub-key")
        XCTAssertEqual(reality["short_id"] as? String, "abcd")
        // Reality SNI must not enter bootstrap domains.
        XCTAssertEqual(plan.tun.uplinkDomains, ["vl.example.com"])
        XCTAssertFalse(plan.tun.uplinkDomains.contains("www.cloudflare.com"))
    }

    func testParseVlessRealityCoercesNumericShortId() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "vless",
                    "server": "89.22.230.136",
                    "server_port": 8443,
                    "uuid": "bf000d23-0752-40b4-affe-68f7707a9661",
                    "flow": "xtls-rprx-vision",
                    "tls": [
                        "server_name": "www.microsoft.com",
                        "reality": [
                            "public_key": "pub-key",
                            "short_id": 12345678,
                        ],
                    ],
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let profile = try XCTUnwrap(ServersApi.parseServerItem([
            "id": "vl-num",
            "name": "SE-VIP-71",
            "protocol": "vless_reality",
            "clientConfigJson": configJSON,
        ]))
        guard case .vlessReality(let vless) = profile.profile else {
            return XCTFail("expected vless")
        }
        XCTAssertEqual(vless.shortId, "12345678")
        XCTAssertEqual(vless.port, 8443)
        XCTAssertEqual(profile.connectPlan.proxyOutbound["server_port"] as? Int, 8443)
        XCTAssertEqual(profile.connectPlan.tun.uplinkDomains, [])
    }

    func testParsePreviewTrojanAndVless() throws {
        let trojan = try XCTUnwrap(ServersApi.parseServerItem([
            "id": "tr-prev",
            "name": "FI-FREE-1",
            "protocol": "trojan",
            "city": "Helsinki",
        ]))
        XCTAssertEqual(trojan.serverProtocol, .trojan)
        XCTAssertFalse(trojan.canConnect)

        let vless = try XCTUnwrap(ServersApi.parseServerItem([
            "id": "vl-prev",
            "name": "DE-FREE-1",
            "protocol": "vless_reality",
        ]))
        XCTAssertEqual(vless.serverProtocol, .vlessReality)
        XCTAssertFalse(vless.canConnect)
    }

    func testVisibleProtocolsFromList() {
        let hy2 = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "FI-FREE-1",
                server: "a.example.com",
                port: 1,
                password: "p",
                tlsServerName: "a.example.com"
            )),
            id: "h1"
        )
        let trojan = ServerProfile(
            profile: .trojan(TrojanProfile(
                displayName: "FI-PLUS-1",
                server: "b.example.com",
                port: 1,
                password: "p",
                tlsServerName: "b.example.com"
            )),
            id: "t1"
        )
        XCTAssertEqual([hy2, trojan].visibleProtocols(), [.hysteria2, .trojan])
        XCTAssertEqual([hy2].visibleProtocols(), [.hysteria2])
    }

    func testTesterTierVisible() {
        let tester = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "FI-TESTER-1",
                server: "a.example.com",
                port: 1,
                password: "p",
                tlsServerName: "a.example.com"
            )),
            id: "t1"
        )
        let free = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "FI-FREE-1",
                server: "b.example.com",
                port: 1,
                password: "p",
                tlsServerName: "b.example.com"
            )),
            id: "f1"
        )
        let tiers = [tester, free].visibleTiers()
        XCTAssertTrue(tiers.contains(.tester))
        XCTAssertTrue(tiers.contains(.free))
        XCTAssertFalse(tiers.contains(.dev))
    }

    func testParseBypassRuleSetsFromClientConfig() throws {
        let config: [String: Any] = [
            "outbounds": [
                [
                    "type": "hysteria2",
                    "server": "hy2.example.com",
                    "server_port": 443,
                    "password": "hy2-pass",
                    "tls": ["server_name": "hy2.example.com", "alpn": ["h3"]],
                ] as [String: Any],
                ["type": "direct", "tag": "direct"] as [String: Any],
            ],
            "route": [
                "final": "FI-FREE-2",
                "rule_set": [
                    [
                        "tag": "geoip-ru",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
                    ],
                    [
                        "tag": "geosite-category-ru",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
                    ],
                    [
                        "tag": "geoip-ir",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ir.srs",
                    ],
                    [
                        "tag": "geosite-ir",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs",
                    ],
                    [
                        "tag": "geoip-cn",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                    ],
                    [
                        "tag": "geosite-cn",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                    ],
                ],
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "route_exclude_address_set": ["geoip-ru", "geoip-ir", "geoip-cn"],
                ] as [String: Any],
            ],
        ]
        let configJSON = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let item: [String: Any] = [
            "id": "def456",
            "name": "FI-FREE-2",
            "protocol": "hysteria2",
            "clientConfigJson": configJSON,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.bypassRuleSets.count, 6)
        XCTAssertTrue(profile.bypassRuleSets.contains {
            $0.tag == "geosite-ir" && $0.url.contains("Chocolate4U")
        })
        XCTAssertEqual(profile.connectPlan.geoipBypassTags, ["geoip-ru", "geoip-ir", "geoip-cn"])
        let built = try SingBoxConfigBuilder.buildTunConfigJson(plan: profile.connectPlan)
        XCTAssertFalse(built.contains("route_exclude_address_set"))
        XCTAssertTrue(built.contains("geosite-ir"))
        XCTAssertFalse(built.contains("\"tag\" : \"geoip-ru\"") || built.contains("\"tag\": \"geoip-ru\""))
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
        XCTAssertNil(proxy["up_mbps"])
        XCTAssertNil(proxy["down_mbps"])
    }

    func testConnectPlanFloorsBandwidthMbpsToTen() throws {
        let profile = Hysteria2Profile(
            displayName: "FI-FREE-1",
            server: "fi.example.com",
            port: 8443,
            password: "secret",
            tlsServerName: "sni.example.com",
            upMbps: 3,
            downMbps: 7
        )
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(profile))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxy["up_mbps"] as? Int, 10)
        XCTAssertEqual(proxy["down_mbps"] as? Int, 10)
    }

    func testConnectPlanKeepsHighBandwidthMbps() throws {
        let profile = Hysteria2Profile(
            displayName: "FI-FREE-1",
            server: "fi.example.com",
            port: 8443,
            password: "secret",
            tlsServerName: "sni.example.com",
            upMbps: 100,
            downMbps: 200
        )
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(profile))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxy["up_mbps"] as? Int, 100)
        XCTAssertEqual(proxy["down_mbps"] as? Int, 200)
    }
}
