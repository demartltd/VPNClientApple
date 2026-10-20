import XCTest
@testable import Demar_Proxy

/// Device/USB network checks for HY2 uplink RTT (must not surface 0ms).
final class UplinkProbeRttTests: XCTestCase {
    func testBlake2b256EmptyAndSalamanderKey() {
        let empty = SalamanderObfs.blake2b256([])
        XCTAssertEqual(
            empty.map { String(format: "%02x", $0) }.joined(),
            "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
        )
        let key = SalamanderObfs.blake2b256(Array("obfs-pass".utf8) + [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "df660a36d9734cd21f02e6db3ce7d3a24f2b18597d12dfe116cb8e5d70807b0a"
        )
    }

    func testSalamanderWrapAddsSaltPrefix() {
        let payload = Data(repeating: 0xAB, count: 1200)
        let wrapped = SalamanderObfs.wrap(payload, password: "obfs-pass")
        XCTAssertEqual(wrapped.count, 1200 + SalamanderObfs.saltLen)
        XCTAssertNotEqual(wrapped.dropFirst(SalamanderObfs.saltLen), payload)
    }

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
