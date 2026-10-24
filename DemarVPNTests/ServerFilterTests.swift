import XCTest
@testable import Demar_Proxy

final class ServerFilterTests: XCTestCase {
    func testFilterServersSortUnlockedFavoritesThenName() {
        let locked = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "AA-PLUS-1",
                server: "a.example.com",
                port: 1,
                password: "",
                tlsServerName: "a.example.com"
            )),
            id: "locked"
        )
        let freeB = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "BB-FREE-1",
                server: "b.example.com",
                port: 1,
                password: "p",
                tlsServerName: "b.example.com"
            )),
            id: "freeB"
        )
        let freeA = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "AA-FREE-1",
                server: "c.example.com",
                port: 1,
                password: "p",
                tlsServerName: "c.example.com"
            )),
            id: "freeA"
        )
        let list = [locked, freeB, freeA].filterServers(
            tiers: Set(ServerTier.allCases),
            protocols: Set(ServerProtocol.allCases),
            favoriteIds: ["freeB"]
        )
        XCTAssertEqual(list.map(\.id), ["freeB", "freeA", "locked"])
    }

    func testMatchesFiltersRejectsEmptyResult() {
        let onlyHy2 = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "FI-FREE-1",
                server: "a.example.com",
                port: 1,
                password: "p",
                tlsServerName: "a.example.com"
            )),
            id: "h1"
        )
        XCTAssertTrue([onlyHy2].matchesFilters(tiers: [.free], protocols: [.hysteria2]))
        XCTAssertFalse([onlyHy2].matchesFilters(tiers: [.vip], protocols: [.hysteria2]))
        XCTAssertFalse([onlyHy2].matchesFilters(tiers: [.free], protocols: [.trojan]))
    }

    /// Spec §3 gate: stale prefs that match nobody must trigger a full reset.
    func testStaleFiltersRequireReset() {
        let onlyHy2 = ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: "FI-FREE-1",
                server: "a.example.com",
                port: 1,
                password: "p",
                tlsServerName: "a.example.com"
            )),
            id: "h1"
        )
        let list = [onlyHy2]
        XCTAssertFalse(list.matchesFilters(tiers: [.vip], protocols: [.trojan]))
        // §9: only badges present in the list.
        XCTAssertEqual(list.visibleTiers(), [.free])
        XCTAssertEqual(list.visibleProtocols(), [.hysteria2])
    }

    /// Spec §9: absent FREE/PLUS/VIP must not appear as filter chips.
    func testVisibleTiersOnlyPresent() {
        let plus = ServerProfile(
            profile: .trojan(TrojanProfile(
                displayName: "DE-PLUS-1",
                server: "a.example.com",
                port: 1,
                password: "p",
                tlsServerName: "a.example.com"
            )),
            id: "p1"
        )
        XCTAssertEqual([plus].visibleTiers(), [.plus])
        XCTAssertEqual([plus].visibleProtocols(), [.trojan])
    }

    func testPickSelectedSkipsLocked() {
        let locked = ServerProfile(
            profile: .trojan(TrojanProfile(
                displayName: "DE-VIP-1",
                server: "a.example.com",
                port: 1,
                password: "",
                tlsServerName: "a.example.com"
            )),
            id: "locked"
        )
        let unlocked = ServerProfile(
            profile: .trojan(TrojanProfile(
                displayName: "DE-FREE-1",
                server: "b.example.com",
                port: 1,
                password: "p",
                tlsServerName: "b.example.com"
            )),
            id: "ok"
        )
        let pick = [locked, unlocked].pickSelected(currentId: "locked", lastId: "locked")
        XCTAssertEqual(pick?.id, "ok")
    }

    func testReachabilityCacheRoundTrip() {
        let src: [String: ServerReachState] = [
            "hy2:FI-FREE-1": ServerReachState(status: .online, latencyMs: 42, tlsMs: 55),
            "hy2:DE-PLUS-2": .offline,
        ]
        let decoded = ServerReachState.decodeCache(ServerReachState.encodeCache(src))
        XCTAssertEqual(decoded["hy2:FI-FREE-1"]?.latencyMs, 42)
        XCTAssertEqual(decoded["hy2:FI-FREE-1"]?.tlsMs, 55)
        XCTAssertEqual(decoded["hy2:DE-PLUS-2"]?.status, .offline)
    }

    func testReachabilityCacheSkipsBareChecking() {
        let json = ServerReachState.encodeCache(["a": .checking])
        XCTAssertTrue(ServerReachState.decodeCache(json).isEmpty)
    }

    func testDirectCountryCodesFromBypass() {
        let sets = [
            ApiBypassRuleSet(tag: "geoip-ru", url: "https://example.com/ru.srs"),
            ApiBypassRuleSet(tag: "geoip-cn", url: "https://example.com/cn.srs"),
            ApiBypassRuleSet(tag: "geosite-ads", url: "https://example.com/ads.srs"),
        ]
        XCTAssertEqual(sets.directCountryCodes(), ["CN", "RU"])
    }

    func testProtocolLabels() {
        XCTAssertEqual(ServerProtocol.hysteria2.label, "HY2")
        XCTAssertEqual(ServerProtocol.trojan.label, "TRJ")
        XCTAssertEqual(ServerProtocol.vlessReality.fullLabel, "VLESS Reality")
        XCTAssertEqual(ServerProtocol.openflux.label, "White")
        XCTAssertEqual(ServerProtocol.openflux.fullLabel, "White List")
        XCTAssertFalse(ServerProtocol.openflux.showsUplinkPing)
        XCTAssertTrue(ServerProtocol.openflux.usesWhiteListVpnMode)
    }

    /// Off-list prefs: only tapped-off badges stay off; new ones default ON (§10).
    func testOffPrefsNewProtocolStaysOn() {
        let key = "demar_servers_off_protocols"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set([ServerProtocol.hysteria2.rawValue], forKey: key)
        let enabled = ServersPreferencesStore.protocols
        XCTAssertFalse(enabled.contains(.hysteria2))
        XCTAssertTrue(enabled.contains(.openflux))
        XCTAssertTrue(enabled.contains(.trojan))
    }
}
