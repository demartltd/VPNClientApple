import XCTest
@testable import Demar_Proxy

final class VpnAccountApiParseTests: XCTestCase {
    func testParseAccount() {
        let a = VpnAccountApi.parseAccount([
            "notifyNews": false,
            "notifyImportant": true,
            "vpnSubscription": "plus",
            "vpnExpiresAt": "2026-12-31T00:00:00.000Z",
        ])
        XCTAssertFalse(a.notifyNews)
        XCTAssertTrue(a.notifyImportant)
        XCTAssertEqual(a.vpnSubscription, "plus")
        XCTAssertEqual(a.vpnExpiresAt, "2026-12-31T00:00:00.000Z")
    }

    func testParseAccountDefaultsAndNullExpiry() {
        let a = VpnAccountApi.parseAccount(["vpnExpiresAt": "null"])
        XCTAssertTrue(a.notifyNews)
        XCTAssertTrue(a.notifyImportant)
        XCTAssertNil(a.vpnSubscription)
        XCTAssertNil(a.vpnExpiresAt)
    }

    func testParseTraffic() {
        let t = VpnAccountApi.parseTraffic([
            "y": 2026,
            "m": 8,
            "total": 1500,
            "limitBytes": 20_000,
            "servers": [
                ["name": "Frankfurt-1", "bytes": 1000],
                ["name": "Amsterdam-2", "bytes": 500],
                ["name": "", "bytes": 99],
            ],
        ])
        XCTAssertEqual(t.y, 2026)
        XCTAssertEqual(t.m, 8)
        XCTAssertEqual(t.total, 1500)
        XCTAssertEqual(t.limitBytes, 20_000)
        XCTAssertEqual(t.servers.count, 2)
        XCTAssertEqual(t.servers[0].name, "Frankfurt-1")
        XCTAssertEqual(t.servers[0].bytes, 1000)
    }

    func testFormatBytes() {
        XCTAssertEqual(VpnAccountApi.formatBytes(500), "500 B")
        XCTAssertEqual(VpnAccountApi.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(VpnAccountApi.formatBytes(10 * 1024 * 1024), "10.0 MB")
    }
}
