import XCTest
@testable import DemarVPN

final class SingBoxConfigTests: XCTestCase {
    func testAllConfigsPassSingBoxCheck() throws {
        for profile in TestServers.profiles {
            try assertSingBoxCheckPasses(json: try SingBoxConfigBuilder.buildTunConfigJson(
                plan: profile.connectPlan
            ))
        }
    }

    func testNaiveOutboundMatchesServerReference() throws {
        let profile = TestServers.naive[0]
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .naive(profile))
        XCTAssertTrue(
            json.contains("\"server\" : \"\(profile.server)\"") ||
            json.contains("\"server\": \"\(profile.server)\"")
        )
        XCTAssertTrue(
            json.contains("\"server_port\" : \(profile.port)") ||
            json.contains("\"server_port\": \(profile.port)")
        )
        XCTAssertTrue(
            json.contains("\"server_name\" : \"\(profile.tlsServerName)\"") ||
            json.contains("\"server_name\": \"\(profile.tlsServerName)\"")
        )
        XCTAssertTrue(json.contains("\"version\" : 2") || json.contains("\"version\": 2"))
        XCTAssertFalse(json.contains("\"predefined\""))
        XCTAssertTrue(json.contains("\"quic\" : false") || json.contains("\"quic\": false"))
        XCTAssertTrue(json.contains("\"final\" : \"dns-remote\"") || json.contains("\"final\": \"dns-remote\""))

        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxyOutbound = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxyOutbound["type"] as? String, "naive")
        XCTAssertNotNil(proxyOutbound["domain_resolver"])

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let dnsServers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let remoteServer = try XCTUnwrap(dnsServers.first { ($0["tag"] as? String) == "dns-remote" })
        XCTAssertEqual(remoteServer["type"] as? String, "https")
        XCTAssertEqual(remoteServer["detour"] as? String, "proxy")
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { rule in
            (rule["query_type"] as? [String]) == ["PTR"]
                && (rule["action"] as? String) == "reject"
                && (rule["method"] as? String) == "drop"
        })
        XCTAssertTrue(dnsRules.contains { rule in
            ((rule["domain"] as? [String])?.contains(profile.tlsServerName) == true)
                && (rule["action"] as? String) == "route"
                && (rule["server"] as? String) == "dns-direct"
        })

        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        let tunInbound = try XCTUnwrap(inbounds.first { ($0["type"] as? String) == "tun" })
        XCTAssertEqual(tunInbound["strict_route"] as? Bool, true)
        XCTAssertEqual(tunInbound["address"] as? [String], ["172.19.0.1/30"])

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let allCIDRs = rules
            .compactMap { $0["ip_cidr"] as? [String] }
            .flatMap { $0 }
        XCTAssertTrue(allCIDRs.isEmpty, "hostname uplink has no build-time IPv4 bypass")
        XCTAssertFalse(allCIDRs.contains("2001:4860:4860::8888/128"))
        XCTAssertFalse(allCIDRs.contains("2606:4700:4700::1111/128"))

        try assertSingBoxCheckPasses(json: json)
    }

    func testHysteria2OutboundMatchesServerReference() throws {
        let profile = TestServers.hysteria2[0]
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(profile))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxy["type"] as? String, "hysteria2")
        XCTAssertEqual(proxy["server"] as? String, profile.server)
        XCTAssertEqual(proxy["server_port"] as? Int, profile.port)
        XCTAssertEqual(proxy["password"] as? String, profile.password)
        XCTAssertNil(proxy["udp_over_tcp"])
        XCTAssertNotNil(proxy["domain_resolver"])
        let tls = try XCTUnwrap(proxy["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, profile.tlsServerName)
        XCTAssertEqual(tls["alpn"] as? [String], ["h3"])
        try assertSingBoxCheckPasses(json: json)
    }

    func testNaiveHostnameServerDirectDomainRouting() throws {
        let profile = TestServers.naive[1]
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .naive(profile))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let domainRules = rules.compactMap { $0["domain"] as? [String] }
        XCTAssertTrue(domainRules.contains { $0.contains(profile.tlsServerName) })
        let allCIDRs = rules.compactMap { $0["ip_cidr"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(allCIDRs.isEmpty, "hostname uplink has no build-time IPv4 bypass")

        let merged = try SingBoxConfigBuilder.mergeDirectIPs(["203.0.113.10"], into: json)
        let mergedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(merged.data(using: .utf8))) as? [String: Any])
        let mergedRoute = try XCTUnwrap(mergedRoot["route"] as? [String: Any])
        let mergedRules = try XCTUnwrap(mergedRoute["rules"] as? [[String: Any]])
        let mergedCIDRs = mergedRules.compactMap { $0["ip_cidr"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(mergedCIDRs.contains("203.0.113.10/32"))
        let tunInbound = try XCTUnwrap((mergedRoot["inbounds"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tun" })
        XCTAssertTrue((tunInbound["route_exclude_address"] as? [String])?.contains("203.0.113.10/32") == true)

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        let uot = try XCTUnwrap(proxy["udp_over_tcp"] as? [String: Any])
        XCTAssertEqual(uot["version"] as? Int, 2)
        try assertSingBoxCheckPasses(json: merged)
    }

    func testSingBoxConfigUsesModernFormat() throws {
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
        XCTAssertFalse(json.contains("\"evaluate\""))
        XCTAssertFalse(json.contains("\"disable_optimistic_cache\""))
    }

    func testJournalTimeFormat() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = c.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 14, minute: 30, second: 45))!
        XCTAssertEqual(DemarLogTime.stamp(date), "2026-06-27-14-30-45")
        XCTAssertEqual(DemarLogTime.journalLine("ping", date: date), "2026-06-27-14-30-45 ping")
        XCTAssertTrue(DemarLogTime.looksPreStamped("2026-06-27-14-30-45 ok"))
        XCTAssertEqual(DemarLogTime.messageBody(in: "2026-06-27-14-30-45 [app] ok"), "[app] ok")
        XCTAssertEqual(DemarLogTime.parseStamp("2026-06-27-14-30-45"), date)
        XCTAssertNil(DemarLogTime.leadingStamp(in: "[2026-06-27-14-30-45] legacy"))
    }

    func testReconfigurePolicySkipsRoutinePathChange() {
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathChange"))
    }

    func testReconfigurePolicySkipsWake() {
        // Wake fires on every unlock; restarting a healthy core flaps the path itself.
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "wake"))
    }

    func testReconfigurePolicySkipsRoutinePathRecovered() {
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathRecovered"))
    }

    func testReconfigurePolicyRestartsOnlyAfterConfirmedPathLoss() {
        XCTAssertTrue(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathRecoveredAfterLoss"))
    }

    private func assertSingBoxCheckPasses(json: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let singboxURL = repoRoot.appendingPathComponent("macos/singbox_macos/sing-box")
        guard FileManager.default.isExecutableFile(atPath: singboxURL.path) else {
            let message = "sing-box binary not found; run scripts/singbox-download-auto.py"
            if ProcessInfo.processInfo.environment["CI"] == "true" {
                XCTFail(message)
            } else {
                throw XCTSkip(message)
            }
            return
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
