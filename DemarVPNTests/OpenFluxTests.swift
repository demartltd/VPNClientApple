import XCTest
@testable import Demar_Proxy

final class OpenFluxTests: XCTestCase {
    /// Same fixture as Android `ServersApiParseTest.parseOpenFlux_fromClientConfigJson`.
    private let fixtureLink =
        "openflux://v1/rY5RCoMwEETP4n6rMa01MSA9SOnHJllJoagkK1XEuxelR-jfMA_ezAaJXCQG8wuFbAoXMKYsgxzcODAtBw3MUzJC2BGjT-WKg6eljLP4hBfT2Yp7wBS6-tairRX2lZS2aTVdVN9qVelayqt26tR6cmDAIrtAHnLgiEOaxsgJzGMDXic6-DkGOczx_d8P-3P_Ag"
    private let boardsUrl =
        "https://boards.yandex.ru/whiteboard/?hash=459ab47af011b698e27f9870841138c7"

    func testDecodeOpenFluxLink() throws {
        let cfg = try OpenFluxLink.decode(fixtureLink)
        XCTAssertEqual(cfg.secret, "secret-16-chars!!")
        XCTAssertEqual(cfg.boardsUrl, boardsUrl)
    }

    func testParseOpenFluxFromClientConfigJson() throws {
        let config: [String: Any] = [
            "engine": "openflux_socks",
            "openfluxLink": fixtureLink,
            "socks": ["host": "127.0.0.1", "port": 11080],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configStr = String(data: configData, encoding: .utf8)!
        let item: [String: Any] = [
            "id": "ofx1",
            "name": "RU-TESTER-1",
            "protocol": "openflux",
            "city": "Moscow",
            "clientConfigJson": configStr,
        ]
        let profile = try XCTUnwrap(ServersApi.parseServerItem(item))
        XCTAssertEqual(profile.serverProtocol, .openflux)
        XCTAssertTrue(profile.serverProtocol.usesWhiteListVpnMode)
        XCTAssertFalse(profile.serverProtocol.showsUplinkPing)
        XCTAssertEqual(profile.protocolBadges().map(\.label), ["White", "SCK"])
        XCTAssertTrue(profile.protocolBadges()[0].whiteList)
        guard case .openflux(let ofx) = profile.profile else {
            return XCTFail("expected openflux")
        }
        XCTAssertEqual(ofx.openfluxLink, fixtureLink)
        XCTAssertEqual(ofx.port, 11080)
        XCTAssertTrue(ofx.hasCredentials)
    }

    func testParseOpenFluxPreviewLocked() {
        let item: [String: Any] = [
            "id": "ofx-preview",
            "name": "RU-TESTER-2",
            "protocol": "openflux",
        ]
        let profile = ServersApi.parseServerItem(item)
        XCTAssertNotNil(profile)
        XCTAssertTrue(profile!.isLocked)
        XCTAssertEqual(profile!.serverProtocol, .openflux)
    }

    func testSocksOutboundAndAntiLoopDomains() throws {
        let ofx = OpenFluxSocksProfile(displayName: "RU-TESTER-1", openfluxLink: fixtureLink)
        let plan = SingBoxConnectPlan.openfluxSocks(ofx)
        XCTAssertEqual(plan.uplinkHost, "127.0.0.1")
        XCTAssertTrue(plan.directIPs.isEmpty)
        XCTAssertTrue(plan.tun.uplinkDomains.isEmpty)
        // Same carrier list as Android OPENFLUX_ANTI_LOOP_DOMAINS (merged into bypassHosts at connect).
        XCTAssertEqual(
            SingBoxConnectPlan.openfluxAntiLoopDomains,
            ["boards.yandex.ru", "yandex.ru", "yandex.net"]
        )
        let json = try SingBoxConfigBuilder.buildTunConfigJson(
            plan: plan,
            bypassHosts: SingBoxConnectPlan.openfluxAntiLoopDomains
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any]
        )
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxy["type"] as? String, "socks")
        XCTAssertEqual(proxy["server"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy["server_port"] as? Int, 11080)
        XCTAssertEqual(proxy["version"] as? String, "5")
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        let hasBoards = dnsRules.contains { rule in
            (rule["domain_suffix"] as? [String])?.contains("boards.yandex.ru") == true
        }
        XCTAssertTrue(hasBoards, "anti-loop boards.yandex.ru must be dns-direct via bypassHosts")
    }

    func testBlankSocksUsesDefaults() {
        let p = OpenFluxSocksProfile(
            displayName: "RU-TESTER-1",
            openfluxLink: "x",
            socksHost: "  ",
            socksPort: 0
        )
        XCTAssertEqual(p.server, OpenFluxSocksProfile.defaultSocksHost)
        XCTAssertEqual(p.port, OpenFluxSocksProfile.defaultSocksPort)
        let plan = SingBoxConnectPlan.openfluxSocks(p)
        XCTAssertEqual(plan.uplinkHost, OpenFluxSocksProfile.defaultSocksHost)
        XCTAssertEqual(plan.proxyOutbound["server_port"] as? Int, OpenFluxSocksProfile.defaultSocksPort)
    }

    func testListPingHiddenForOpenFlux() {
        let online = ServerReachState(status: .online, latencyMs: 10, tlsMs: 20)
        XCTAssertEqual(ServerReachState.formatListLabel(online, protocol: .openflux), "")
        XCTAssertEqual(ServerReachState.formatListLabel(online, protocol: .trojan), "~20ms")
    }

    func testProbeOpenFluxOnlineWithoutMs() async {
        let profile = ServerProfile(
            profile: .openflux(OpenFluxSocksProfile(displayName: "RU-TESTER-1", openfluxLink: fixtureLink)),
            id: "ofx1"
        )
        let state = await UplinkProbe.probe(profile)
        XCTAssertEqual(state.status, .online)
        XCTAssertNil(state.latencyMs)
        XCTAssertNil(state.tlsMs)
    }
}
