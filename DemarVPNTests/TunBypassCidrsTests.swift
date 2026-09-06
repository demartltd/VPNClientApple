import XCTest
import NetworkExtension
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
        // Aggregated (coarsen ≤/16) — far below raw sing-geoip dump (~8k/1.7k/5k).
        XCTAssertGreaterThan(ru.count, 100)
        XCTAssertLessThan(ru.count, 3000)
        XCTAssertGreaterThan(ir.count, 50)
        XCTAssertLessThan(ir.count, 1500)
        XCTAssertGreaterThan(cn.count, 100)
        XCTAssertLessThan(cn.count, 3000)
        XCTAssertTrue(ru.contains { $0.hasPrefix("2.56.") })
        let routes = TunBypassCidrs.ipv4Routes(forTags: ["geoip-ru", "geoip-ir", "geoip-cn"])
        XCTAssertEqual(routes.count, Set(ru + ir + cn).count)
    }

    func testIpv4RoutesCacheReusesInstance() {
        let tags = ["geoip-ru"]
        let a = TunBypassCidrs.ipv4Routes(forTags: tags)
        let b = TunBypassCidrs.ipv4Routes(forTags: tags)
        XCTAssertEqual(a.count, b.count)
        XCTAssertFalse(a.isEmpty)
    }
}
