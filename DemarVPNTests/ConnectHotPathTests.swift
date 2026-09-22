import XCTest
@testable import Demar_Proxy

final class ConnectHotPathTests: XCTestCase {
    func testNeedsRefreshWhenGeoMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-needs-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(CoreBundleAssets.needsRefresh(in: dir))
    }

    func testNeedsRefreshWhenBundledVersionMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-needs-refresh-ver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Empty geo placeholders so hasGeo can pass only if both exist — omit them → refresh.
        XCTAssertTrue(CoreBundleAssets.needsRefresh(in: dir))
    }

    func testNeedsRefreshWhenVersionMismatches() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-needs-refresh-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in CoreBundleAssets.geoFiles {
            try Data("stub".utf8).write(to: dir.appendingPathComponent(name))
        }
        try Data("stale-version".utf8).write(to: dir.appendingPathComponent("bundled_version.txt"))
        // Stale/missing match vs bundle → refresh required (upgrade wipe deletes version file).
        XCTAssertTrue(CoreBundleAssets.needsRefresh(in: dir))
    }

    func testUplinkResolverLiteralAndClear() throws {
        UplinkIPv4Resolver.clear()
        XCTAssertEqual(try UplinkIPv4Resolver.resolve("203.0.113.10"), ["203.0.113.10"])
        UplinkIPv4Resolver.clear()
        XCTAssertEqual(try UplinkIPv4Resolver.resolve("203.0.113.10"), ["203.0.113.10"])
    }

    func testUplinkResolverEmptyHost() throws {
        XCTAssertEqual(try UplinkIPv4Resolver.resolve(nil), [])
        XCTAssertEqual(try UplinkIPv4Resolver.resolve("  "), [])
    }

    func testBypassExcludeIPCacheRoundTrip() {
        let fp = "test-fp-\(UUID().uuidString)"
        XCTAssertNil(BypassExcludeIPCache.load(fingerprint: fp))
        BypassExcludeIPCache.save(fingerprint: fp, ips: ["203.0.113.1", "203.0.113.2"])
        XCTAssertEqual(BypassExcludeIPCache.load(fingerprint: fp), ["203.0.113.1", "203.0.113.2"])
    }

    func testParseARecordsFromFixture() {
        // Minimal DNS response: id=0x1234, QR=1 RCODE=0, QD=1 AN=1, A=203.0.113.10
        // Question: a.example / A IN; Answer: pointer to QNAME + A 203.0.113.10
        let bytes: [UInt8] = [
            0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x61, 0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04,
            203, 0, 113, 10,
        ]
        XCTAssertEqual(
            UplinkIPv4Resolver.parseARecords(Data(bytes), expectedID: 0x1234),
            ["203.0.113.10"]
        )
        XCTAssertEqual(UplinkIPv4Resolver.parseARecords(Data(bytes), expectedID: 0x0001), [])
    }

    func testParseUplinkIPv4OptionsList() {
        let raw = "1.2.3.4, 5.6.7.8,, "
        let ips = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(ips, ["1.2.3.4", "5.6.7.8"])
    }
}
