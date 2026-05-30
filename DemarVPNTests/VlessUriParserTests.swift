import XCTest
@testable import DemarVPN

final class VlessUriParserTests: XCTestCase {
    private let simpleTcpReality = """
        vless://e028cc9a-259c-4971-828c-f3611c7eb98c@194.31.223.29:443?\
        encryption=none&type=tcp&security=reality&sni=example.com&fp=chrome&\
        pbk=8zUdD30jyEClX2CdvUa0F6PB8x1YmjiHxt94jf7U8jI&sid=1de1#simple
        """

    func testXhttpProfileRejectedForSingBox() throws {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@194.31.223.29:443?\
            encryption=none&type=xhttp&security=reality&sni=example.com&fp=chrome&\
            pbk=8zUdD30jyEClX2CdvUa0F6PB8x1YmjiHxt94jf7U8jI&sid=1de1&mode=auto
            """
        let profile = try VlessUriParser.parse(uri)
        XCTAssertEqual(profile.network, "xhttp")
        XCTAssertThrowsError(try SingBoxConfigBuilder.buildTunConfigJson(profile: profile))
    }

    func testSimpleTcpRealityRegression() throws {
        let profile = try VlessUriParser.parse(simpleTcpReality)
        XCTAssertEqual(profile.network, "tcp")
        XCTAssertEqual(profile.encryption, "none")

        let json = try SingBoxConfigBuilder.buildTunConfigJson(profile: profile)
        XCTAssertTrue(json.contains("\"type\" : \"vless\"") || json.contains("\"type\": \"vless\""))
        XCTAssertTrue(json.contains("\"network\" : \"tcp\"") || json.contains("\"network\": \"tcp\""))
        XCTAssertTrue(json.contains("\"reality\""))
        XCTAssertFalse(json.contains("xhttpSettings"))
        XCTAssertFalse(json.contains("\"encryption\""))
    }

    func testSplithttpAliasNormalizesToXhttpAndRejected() throws {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@1.2.3.4:443?\
            encryption=none&type=splithttp&security=reality&sni=x.test&\
            pbk=8zUdD30jyEClX2CdvUa0F6PB8x1YmjiHxt94jf7U8jI&sid=ab&path=%2Fcdn
            """
        let profile = try VlessUriParser.parse(uri)
        XCTAssertEqual(profile.network, "xhttp")
        XCTAssertThrowsError(try SingBoxConfigBuilder.buildTunConfigJson(profile: profile))
    }

    func testGeneratedConfigPassesSingBoxCheck() throws {
        guard let firstURI = TestServers.uris.first else {
            throw XCTSkip("No VLESS test URIs configured in TestServers.uris")
        }
        let profile = try VlessUriParser.parse(firstURI)
        XCTAssertNoThrow(try SingBoxConfigBuilder.buildPreflightTestJson(profile: profile))
    }

    func testGeneratedConfigPassesSingBoxCheckForCompatibleTcpReality() throws {
        try assertSingBoxCheckPasses(json: try SingBoxConfigBuilder.buildPreflightTestJson(
            profile: try VlessUriParser.parse(simpleTcpReality)
        ))
    }

    func testNaiveConfigPassesSingBoxCheck() throws {
        try assertSingBoxCheckPasses(json: try SingBoxConfigBuilder.buildTunConfigJson(
            profile: TestServers.naive[0]
        ))
    }

    func testNaiveOutboundMatchesServerReference() throws {
        let profile = TestServers.naive[0]
        let json = try SingBoxConfigBuilder.buildTunConfigJson(profile: profile)
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

    private func assertSingBoxCheckPasses(json: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let singboxURL = repoRoot.appendingPathComponent("macos/singbox_macos/sing-box")
        guard FileManager.default.isExecutableFile(atPath: singboxURL.path) else {
            throw XCTSkip("sing-box binary not found; run scripts/singbox-download-auto.py")
        }

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-vless-core-test-\(UUID().uuidString).json")
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

    func testSingBoxConfigUses13Format() throws {
        let json = try SingBoxConfigBuilder.buildTunConfigJson(profile: TestServers.naive[0])
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

    func testInvalidExtraJSONThrows() {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@1.2.3.4:443?\
            encryption=none&type=xhttp&security=reality&sni=x.test&\
            pbk=8zUdD30jyEClX2CdvUa0F6PB8x1YmjiHxt94jf7U8jI&sid=ab&extra=not-json
            """
        XCTAssertThrowsError(try VlessUriParser.parse(uri))
    }

    func testRuntimeStrictRejectsMissingSecurity() {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@1.2.3.4:443?\
            encryption=none&type=tcp#strict
            """
        XCTAssertThrowsError(try VlessUriParser.parse(uri, mode: .runtimeStrict))
    }

    func testRuntimeStrictRejectsSecurityNone() {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@1.2.3.4:443?\
            security=none&encryption=none&type=tcp#strict-none
            """
        XCTAssertThrowsError(try VlessUriParser.parse(uri, mode: .runtimeStrict))
    }

    func testSingBoxRejectsPqvParameter() throws {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@1.2.3.4:443?\
            encryption=none&type=tcp&security=reality&sni=x.test&pbk=pk&sid=ab&pqv=abc
            """
        let profile = try VlessUriParser.parse(uri)
        XCTAssertThrowsError(try SingBoxConfigBuilder.buildTunConfigJson(profile: profile))
    }

    func testSingBoxRejectsNonNoneEncryption() throws {
        let uri = """
            vless://e028cc9a-259c-4971-828c-f3611c7eb98c@1.2.3.4:443?\
            encryption=mlkem768x25519plus&type=tcp&security=reality&sni=x.test&pbk=pk&sid=ab
            """
        let profile = try VlessUriParser.parse(uri)
        XCTAssertThrowsError(try SingBoxConfigBuilder.buildTunConfigJson(profile: profile))
    }

    func testReconfigurePolicySkipsStableRoutes() {
        XCTAssertFalse(
            VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(
                reason: "pathChange",
                heartbeatFresh: true,
                tunHealthy: true
            )
        )
        XCTAssertFalse(
            VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(
                reason: "wake",
                heartbeatFresh: true,
                tunHealthy: true
            )
        )
    }

    func testReconfigurePolicyAllowsRecoveryRestart() {
        XCTAssertTrue(
            VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(
                reason: "pathChange",
                heartbeatFresh: false,
                tunHealthy: true
            )
        )
        XCTAssertTrue(
            VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(
                reason: "wake",
                heartbeatFresh: true,
                tunHealthy: false
            )
        )
        XCTAssertTrue(
            VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(
                reason: "pathRecovered",
                heartbeatFresh: true,
                tunHealthy: true
            )
        )
    }
}
