import XCTest
@testable import DemarVPN

final class SingBoxConfigTests: XCTestCase {
    func testNaiveConfigPassesSingBoxCheck() throws {
        try assertSingBoxCheckPasses(json: try SingBoxConfigBuilder.buildTunConfigJson(
            plan: TestServers.profiles[0].connectPlan
        ))
    }

    func testNaiveOutboundMatchesServerReference() throws {
        let profile = TestServers.naive[0]
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .naive(profile))
        XCTAssertTrue(
            json.contains("\"server\" : \"\(profile.server)\"") ||
            json.contains("\"server\": \"\(profile.server)\"")
        )
        XCTAssertTrue(
            json.contains("\"server_name\" : \"\(profile.tlsServerName)\"") ||
            json.contains("\"server_name\": \"\(profile.tlsServerName)\"")
        )
        XCTAssertFalse(json.contains("\"version\""))
        XCTAssertFalse(json.contains("\"predefined\""))
        XCTAssertTrue(json.contains("\"quic\" : false") || json.contains("\"quic\": false"))
        XCTAssertTrue(json.contains("\"final\" : \"dns-remote\"") || json.contains("\"final\": \"dns-remote\""))

        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxyOutbound = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertNotNil(proxyOutbound["domain_resolver"])

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let dnsServers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let remoteServer = try XCTUnwrap(dnsServers.first { ($0["tag"] as? String) == "dns-remote" })
        XCTAssertEqual(remoteServer["type"] as? String, "https")
        XCTAssertEqual(remoteServer["detour"] as? String, "proxy")

        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        let tunInbound = try XCTUnwrap(inbounds.first { ($0["type"] as? String) == "tun" })
        XCTAssertEqual(tunInbound["strict_route"] as? Bool, true)
        XCTAssertEqual(tunInbound["address"] as? [String], ["172.19.0.1/30"])

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let allCIDRs = rules
            .compactMap { $0["ip_cidr"] as? [String] }
            .flatMap { $0 }
        XCTAssertFalse(allCIDRs.contains("2001:4860:4860::8888/128"))
        XCTAssertFalse(allCIDRs.contains("2606:4700:4700::1111/128"))

        try assertSingBoxCheckPasses(json: json)
    }

    func testSingBoxConfigUses13Format() throws {
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .naive(TestServers.naive[0]))
        XCTAssertTrue(json.contains("\"route\""))
        XCTAssertFalse(json.contains("\"routing\""))
        XCTAssertFalse(json.contains("inet4_address"))
        XCTAssertFalse(json.contains("inet4_route_address"))
        XCTAssertFalse(json.contains("network_strategy"))
        XCTAssertFalse(json.contains("domain_strategy"))
        XCTAssertFalse(json.contains("\"sniff\" : true") || json.contains("\"sniff\": true"))
        XCTAssertTrue(json.contains("default_domain_resolver"))
        XCTAssertTrue(json.contains("\"action\" : \"sniff\"") || json.contains("\"action\": \"sniff\""))
    }

    func testReconfigurePolicySkipsRoutinePathChange() {
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathChange"))
    }

    func testReconfigurePolicySkipsWake() {
        // Wake fires on every unlock; restarting a healthy core flaps the path itself.
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "wake"))
    }

    func testReconfigurePolicyRestartsOnPathRecovered() {
        XCTAssertTrue(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathRecovered"))
    }

    private func assertSingBoxCheckPasses(json: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let singboxURL = repoRoot.appendingPathComponent("macos/singbox_macos/sing-box")
        guard FileManager.default.isExecutableFile(atPath: singboxURL.path) else {
            throw XCTSkip("sing-box binary not found; run scripts/singbox-download-auto.py")
        }

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-singbox-test-\(UUID().uuidString).json")
        try json.write(to: configURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let process = Process()
        process.executableURL = singboxURL
        process.arguments = ["check", "-c", configURL.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = errPipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "sing-box check failed:\n\(output)\nconfig: \(configURL.path)"
        )
    }
}
