import XCTest
@testable import Demar_Proxy

final class TunGroupsParseTests: XCTestCase {
    private let sampleJSON = """
    {
      "windows": [{"name":"Browsers","enabledByDefault":true,"apps":[{"id":"chrome.exe","name":"Chrome"}]}],
      "sites": [
        {
          "name": "Social",
          "enabledByDefault": true,
          "isWhiteList": false,
          "sites": [
            {"host":"instagram.com","name":"Instagram"},
            {"host":"tiktok.com","name":"TikTok"}
          ]
        },
        {
          "name": "Optional",
          "enabledByDefault": false,
          "sites": [{"host":"example.com","name":"Example"}]
        },
        {
          "name": "WL Sites",
          "enabledByDefault": true,
          "isWhiteList": true,
          "sites": [{"host":"vk.com","name":"VK"}]
        }
      ]
    }
    """

    func testParseIgnoresWindowsKeepsSites() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        XCTAssertEqual(catalog.siteGroups.count, 3)
        XCTAssertEqual(catalog.siteGroups[0].id, "social")
        XCTAssertFalse(catalog.siteGroups[0].isWhiteList)
        XCTAssertEqual(catalog.siteGroups[0].sites.map(\.host), ["instagram.com", "tiktok.com"])
        XCTAssertEqual(catalog.siteGroups[1].enabledByDefault, false)
        XCTAssertTrue(catalog.siteGroups[2].isWhiteList)
        XCTAssertEqual(catalog.siteGroups[2].sites.map(\.host), ["vk.com"])
    }

    func testWhiteListVpnModeOmitsWhiteListHostsFromBypass() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(siteGroupOverrides: [:], rulesEnabled: true)
        let normal = TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: false)
        let wl = TunEffective.bypassHosts(
            settings: settings,
            catalog: catalog,
            isFree: false,
            whiteListVpnMode: true
        )
        XCTAssertTrue(normal.contains("vk.com"))
        XCTAssertTrue(normal.contains("instagram.com"))
        XCTAssertFalse(wl.contains("vk.com"))
        XCTAssertTrue(wl.contains("instagram.com"))
        let fpN = TunEffective.fingerprint(settings: settings, catalog: catalog, isFree: false)
        let fpW = TunEffective.fingerprint(
            settings: settings,
            catalog: catalog,
            isFree: false,
            whiteListVpnMode: true
        )
        XCTAssertNotEqual(fpN, fpW)
        XCTAssertTrue(fpW.contains("wl=true"))
    }

    func testUntouchedGroupsFollowApiDefaults() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(siteGroupOverrides: [:], rulesEnabled: true)
        let expected = ["instagram.com", "tiktok.com", "vk.com"]
        XCTAssertEqual(TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: false), expected)
        XCTAssertEqual(TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: true), expected)
    }

    func testFreeRespectsOverridesLikePaid() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(siteGroupOverrides: ["social": false], rulesEnabled: true)
        // social off → only WL Sites (vk.com) remain from defaults
        XCTAssertEqual(
            TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: true),
            ["vk.com"]
        )
        XCTAssertEqual(
            TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: false),
            ["vk.com"]
        )
    }

    func testPaidRespectsOverridesAndDefaults() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(siteGroupOverrides: ["optional": true], rulesEnabled: true)
        let hosts = TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: false)
        XCTAssertEqual(hosts, ["example.com", "instagram.com", "tiktok.com", "vk.com"])
    }

    func testRulesDisabledClearsHosts() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(siteGroupOverrides: [:], rulesEnabled: false)
        XCTAssertTrue(TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: false).isEmpty)
        XCTAssertFalse(TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: true).isEmpty)
    }

    func testNormalizeHostStripsSchemePathWildcard() {
        XCTAssertEqual(TunEffective.normalizeHost("https://Instagram.com/path"), "instagram.com")
        XCTAssertEqual(TunEffective.normalizeHost("*.TikTok.com."), "tiktok.com")
        XCTAssertEqual(TunEffective.normalizeHost("  EXAMPLE.COM?x=1  "), "example.com")
        XCTAssertNil(TunEffective.normalizeHost("://"))
        XCTAssertNil(TunEffective.normalizeHost("   "))
    }

    func testParseBypassHostNormalizesUrlAndWww() {
        XCTAssertEqual(TunEffective.parseBypassHost("https://www.youtube.com/watch?"), "youtube.com")
        XCTAssertEqual(TunEffective.parseBypassHost("www.youtube.com"), "youtube.com")
        XCTAssertEqual(TunEffective.parseBypassHost("youtube.com"), "youtube.com")
        XCTAssertEqual(TunEffective.parseBypassHost("  https://Example.com/path?q=1  "), "example.com")
        XCTAssertNil(TunEffective.parseBypassHost(""))
        XCTAssertNil(TunEffective.parseBypassHost("   "))
        XCTAssertNil(TunEffective.parseBypassHost("not a host"))
        XCTAssertNil(TunEffective.parseBypassHost("hello"))
        XCTAssertNil(TunEffective.parseBypassHost("localhost"))
        XCTAssertNil(TunEffective.parseBypassHost("1.2.3.4"))
        XCTAssertNil(TunEffective.parseBypassHost("-bad.com"))
        XCTAssertEqual(
            TunEffective.parseBypassHosts("hello, example.com, localhost, 1.2.3.4"),
            ["example.com"]
        )
    }

    func testParseBypassHostsSplitsCommaAndWhitespace() {
        XCTAssertEqual(
            TunEffective.parseBypassHosts("https://www.youtube.com/watch?, example.com  reddit.com"),
            ["example.com", "reddit.com", "youtube.com"]
        )
        XCTAssertEqual(TunEffective.parseBypassHosts("youtube.com"), ["youtube.com"])
        XCTAssertEqual(TunEffective.parseBypassHosts("  ,  "), [])
    }

    func testCustomBypassHostsMergeWithGroups() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(
            siteGroupOverrides: [:],
            rulesEnabled: true,
            bypassHosts: ["reddit.com", "youtube.com"]
        )
        XCTAssertEqual(
            TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: false),
            ["instagram.com", "reddit.com", "tiktok.com", "vk.com", "youtube.com"]
        )
        // Free: custom hosts stored/shown, not applied.
        XCTAssertEqual(
            TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: true),
            ["instagram.com", "tiktok.com", "vk.com"]
        )
        let off = TunSettings(
            siteGroupOverrides: [:],
            rulesEnabled: false,
            bypassHosts: ["reddit.com"]
        )
        XCTAssertTrue(TunEffective.bypassHosts(settings: off, catalog: catalog, isFree: false).isEmpty)
    }

    func testCustomBypassHostsRemainInWhiteListVpnMode() {
        let catalog = TunGroupsApi.parse(sampleJSON)
        let settings = TunSettings(
            siteGroupOverrides: [:],
            rulesEnabled: true,
            bypassHosts: ["twitch.tv", "youtube.com"]
        )
        let wl = TunEffective.bypassHosts(
            settings: settings,
            catalog: catalog,
            isFree: false,
            whiteListVpnMode: true
        )
        XCTAssertTrue(wl.contains("twitch.tv"))
        XCTAssertTrue(wl.contains("youtube.com"))
        XCTAssertTrue(wl.contains("instagram.com"))
        XCTAssertFalse(wl.contains("vk.com"))
    }

    func testExcludeResolveHostsAddsWww() {
        XCTAssertEqual(
            TunEffective.excludeResolveHosts(["twitch.tv"]),
            ["twitch.tv", "www.twitch.tv"]
        )
        XCTAssertEqual(
            TunEffective.excludeResolveHosts(["www.twitch.tv"]),
            ["www.twitch.tv"]
        )
        XCTAssertEqual(
            TunEffective.excludeResolveHosts(["twitch.tv", "www.twitch.tv"]),
            ["twitch.tv", "www.twitch.tv"]
        )
    }

    func testAdBlockDefaultOffAndFreeForcedOff() {
        XCTAssertNil(TunSettings.empty.adBlockEnabled)
        XCTAssertFalse(TunEffective.isAdBlockEnabled(.empty, isFree: true))
        XCTAssertTrue(TunEffective.isAdBlockEnabled(.empty, isFree: false))
        let off = TunSettings(siteGroupOverrides: [:], rulesEnabled: true, adBlockEnabled: false)
        XCTAssertFalse(TunEffective.isAdBlockEnabled(off, isFree: false))
        let on = TunSettings(siteGroupOverrides: [:], rulesEnabled: true, adBlockEnabled: true)
        XCTAssertTrue(TunEffective.isAdBlockEnabled(on, isFree: false))
        XCTAssertFalse(TunEffective.isAdBlockEnabled(on, isFree: true))
    }

    func testBypassHostsNormalizesDirtyApiHosts() {
        let catalog = TunCatalog(siteGroups: [
            TunSiteGroup(
                id: "dirty",
                name: "Dirty",
                sites: [
                    TunSiteRef(host: "https://Instagram.com/foo", name: "IG"),
                    TunSiteRef(host: "*.tiktok.com.", name: "TT"),
                    TunSiteRef(host: "instagram.com", name: "IG2"),
                ],
                enabledByDefault: true
            ),
        ])
        let hosts = TunEffective.bypassHosts(
            settings: .empty,
            catalog: catalog,
            isFree: true
        )
        XCTAssertEqual(hosts, ["instagram.com", "tiktok.com"])
    }

    func testSessionCacheTunRoundTrip() {
        let userId = "tun-cache-test-user"
        SessionCacheStore.clear()
        TunSettingsStore.clearCatalog()

        let serversJson: [String: Any] = [
            "servers": [[
                "id": "s1",
                "name": "Test",
                "protocol": "hysteria2",
            ]],
            "vpnSubscription": "free",
        ]
        SessionCacheStore.saveServers(serversJson, userId: userId)
        SessionCacheStore.saveTun(sampleJSON, userId: userId)

        let snap = SessionCacheStore.load(userId: userId)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.tunRaw, sampleJSON.trimmingCharacters(in: .whitespacesAndNewlines))
        TunSettingsStore.hydrateFromCache(snap?.tunRaw)
        XCTAssertEqual(TunSettingsStore.currentCatalog.siteGroups.count, 3)

        SessionCacheStore.clear()
        TunSettingsStore.clearCatalog()
        XCTAssertTrue(TunSettingsStore.currentCatalog.siteGroups.isEmpty)
    }
}
