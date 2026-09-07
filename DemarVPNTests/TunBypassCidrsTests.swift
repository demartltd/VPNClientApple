import XCTest
import NetworkExtension
#if canImport(Darwin)
import Darwin
#endif
@testable import Demar_Proxy

final class TunBypassCidrsTests: XCTestCase {
    func testIPv4RouteFromCidr() throws {
        let route = try XCTUnwrap(TunBypassCidrs.ipv4Route(cidr: "203.0.113.0/24"))
        XCTAssertEqual(route.destinationAddress, "203.0.113.0")
        XCTAssertEqual(route.destinationSubnetMask, "255.255.255.0")
        XCTAssertNil(TunBypassCidrs.ipv4Route(cidr: "not-a-cidr"))
        XCTAssertNil(TunBypassCidrs.ipv4Route(cidr: "2001:db8::/32"))
    }

    func testBundledGeoipSidecarsLoad() {
        let ru = TunBypassCidrs.loadCidrs(tag: "geoip-ru")
        let ir = TunBypassCidrs.loadCidrs(tag: "geoip-ir")
        let cn = TunBypassCidrs.loadCidrs(tag: "geoip-cn")
        // Aggregated (coarsen ≤/20) — below raw sing-geoip dump (~8k/1.7k/5k).
        XCTAssertGreaterThan(ru.count, 100)
        XCTAssertLessThan(ru.count, 8000)
        XCTAssertGreaterThan(ir.count, 50)
        XCTAssertLessThan(ir.count, 3000)
        XCTAssertGreaterThan(cn.count, 100)
        XCTAssertLessThan(cn.count, 6000)
        XCTAssertTrue(ru.contains { $0.hasPrefix("2.56.") })
        let routes = TunBypassCidrs.ipv4Routes(forTags: ["geoip-ru", "geoip-ir", "geoip-cn"])
        XCTAssertEqual(routes.count, Set(ru + ir + cn).count)
    }

    func testBundledSidecarsDoNotCoverTelegramDCSamples() {
        let routes = TunBypassCidrs.ipv4Routes(forTags: ["geoip-ru", "geoip-ir", "geoip-cn"])
        let samples = [
            "149.154.167.51",
            "149.154.175.50",
            "91.108.56.165",
            "91.108.4.5",
            "95.161.64.1",
        ]
        for ip in samples {
            XCTAssertFalse(
                routes.contains { routeContains($0, ip: ip) },
                "Telegram DC \(ip) must stay in TUN (not NE excludedRoutes)"
            )
        }
    }

    func testIpv4RoutesCacheReusesInstance() {
        let tags = ["geoip-ru"]
        let a = TunBypassCidrs.ipv4Routes(forTags: tags)
        let b = TunBypassCidrs.ipv4Routes(forTags: tags)
        XCTAssertEqual(a.count, b.count)
        XCTAssertFalse(a.isEmpty)
    }

    private func routeContains(_ route: NEIPv4Route, ip: String) -> Bool {
        guard let dest = ipv4(route.destinationAddress),
              let mask = ipv4(route.destinationSubnetMask),
              let addr = ipv4(ip)
        else { return false }
        return (addr & mask) == (dest & mask)
    }

    private func ipv4(_ value: String) -> UInt32? {
        var addr = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}
