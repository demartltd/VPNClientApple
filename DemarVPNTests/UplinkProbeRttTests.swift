import XCTest
@testable import Demar_Proxy

/// Device/USB network checks for HY2 uplink RTT (must not surface 0ms).
final class UplinkProbeRttTests: XCTestCase {
    func testSuccessfulProbeRttAtLeastOneMs() async {
        // Known HY2 host from production list (UDP 8443).
        let host = "de-f-1.xyzdeer.space"
        let port: UInt16 = 8443
        let tcp = await PublicEgressDiagnostics.probeTcpMs(host, port: port)
        let quic = await PublicEgressDiagnostics.probeQuicMs(host, port: port)
        if tcp >= 0 {
            XCTAssertGreaterThanOrEqual(tcp, 1, "tcp RTT must not be 0ms (got \(tcp))")
        }
        if quic >= 0 {
            XCTAssertGreaterThanOrEqual(quic, 1, "quic RTT must not be 0ms (got \(quic))")
        }
        // At least one channel should succeed on a live HY2 uplink.
        XCTAssertTrue(tcp >= 0 || quic >= 0, "tcp=\(tcp) quic=\(quic)")
    }

    func testFiHy2FallbackNotZeroWhenQuicFails() async {
        let host = "fi-f-2.xyzdeer.space"
        let port: UInt16 = 8443
        let tcp = await PublicEgressDiagnostics.probeTcpMs(host, port: port)
        let quic = await PublicEgressDiagnostics.probeQuicMs(host, port: port)
        if tcp >= 0 {
            XCTAssertGreaterThanOrEqual(tcp, 1, "tcp fallback RTT must not be 0ms (got \(tcp))")
        }
        // Log pair for journal-style diagnosis in CI output.
        print("InternetProbe \(host):\(port) tcp=\(tcp) quic=\(quic)")
    }
}
