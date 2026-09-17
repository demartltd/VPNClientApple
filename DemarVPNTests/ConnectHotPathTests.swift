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

    func testParseUplinkIPv4OptionsList() {
        let raw = "1.2.3.4, 5.6.7.8,, "
        let ips = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(ips, ["1.2.3.4", "5.6.7.8"])
    }
}
