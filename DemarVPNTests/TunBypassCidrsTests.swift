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
        XCTAssertGreaterThan(ru.count, 1000)
        XCTAssertGreaterThan(ir.count, 100)
        XCTAssertGreaterThan(cn.count, 1000)
        XCTAssertTrue(ru.contains("2.56.24.0/22"))
        let routes = TunBypassCidrs.ipv4Routes(forTags: ["geoip-ru", "geoip-ir", "geoip-cn"])
        XCTAssertEqual(routes.count, ru.count + ir.count + cn.count)
    }
}
