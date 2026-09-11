import XCTest
@testable import Demar_Proxy

final class SingBoxConfigTests: XCTestCase {
    func testAllConfigsPassSingBoxCheck() throws {
        for profile in TestServers.profiles {
            try assertSingBoxCheckPasses(json: try SingBoxConfigBuilder.buildTunConfigJson(
                plan: profile.connectPlan
            ))
        }
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
        XCTAssertEqual(proxy["udp_fragment"] as? Bool, true)
        XCTAssertNil(proxy["udp_over_tcp"])
        XCTAssertNotNil(proxy["domain_resolver"])
        let tls = try XCTUnwrap(proxy["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, profile.tlsServerName)
        XCTAssertEqual(tls["alpn"] as? [String], ["h3"])

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(dns["final"] as? String, "dns-remote")
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertEqual(log["level"] as? String, "info")
        XCTAssertEqual(log["timestamp"] as? Bool, true)
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
        XCTAssertNotNil(outbounds.first { ($0["tag"] as? String) == "direct" })

        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tun" })
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["mtu"] as? Int, 4064)
        XCTAssertEqual(tun["strict_route"] as? Bool, false)
        XCTAssertEqual(tun["endpoint_independent_nat"] as? Bool, false)
        XCTAssertEqual(tun["address"] as? [String], ["172.19.0.1/30"])
        XCTAssertEqual(tun["route_address"] as? [String], ["0.0.0.0/1", "128.0.0.0/1"])

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")
        XCTAssertEqual(rules.first?["timeout"] as? String, "300ms")
        XCTAssertEqual(rules.first?["timeout"] as? String, "300ms")
        XCTAssertTrue(rules.contains {
            ($0["network"] as? [String]) == ["udp"]
                && ($0["port"] as? [Int]) == [443]
                && ($0["action"] as? String) == "reject"
                && ($0["method"] as? String) == "default"
        })
        XCTAssertTrue(rules.contains {
            ($0["ip_version"] as? Int) == 6
                && ($0["action"] as? String) == "reject"
                && ($0["method"] as? String) == "default"
        })

        try assertSingBoxCheckPasses(json: json)
    }

    func testCoreVersionIsPinnedToValidatedRelease() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let version = try String(
            contentsOf: repoRoot.appendingPathComponent("singbox-version.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version, "v1.13.14")
        for relativePath in [
            "ios/Shared/singbox/bundled_version.txt",
            "macos/singbox_macos/bundled_version.txt",
        ] {
            let bundled = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(bundled, version)
        }
    }

    func testHysteria2HostnamePinAndDirectDomainRouting() throws {
        let profile = TestServers.hysteria2[0]
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(profile))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let domainRules = rules.compactMap { $0["domain"] as? [String] }
        XCTAssertTrue(domainRules.contains { $0.contains(profile.tlsServerName) })
        XCTAssertTrue(domainRules.contains { $0.contains(profile.server) })
        let allCIDRs = rules.compactMap { $0["ip_cidr"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(allCIDRs.isEmpty, "hostname uplink has no build-time IPv4 bypass")

        let merged = try SingBoxConfigBuilder.mergeDirectIPs(
            ["203.0.113.10"],
            into: json,
            dialTag: SingBoxConfigConstants.proxyTag
        )
        let mergedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(merged.data(using: .utf8))) as? [String: Any])
        let mergedRoute = try XCTUnwrap(mergedRoot["route"] as? [String: Any])
        let mergedRules = try XCTUnwrap(mergedRoute["rules"] as? [[String: Any]])
        let mergedCIDRs = mergedRules.compactMap { $0["ip_cidr"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(mergedCIDRs.contains("203.0.113.10/32"))
        let bypassIndex = try XCTUnwrap(mergedRules.firstIndex {
            ($0["ip_cidr"] as? [String]) == ["203.0.113.10/32"]
        })
        let ipv6RejectIndex = try XCTUnwrap(mergedRules.firstIndex { ($0["ip_version"] as? Int) == 6 })
        XCTAssertLessThan(bypassIndex, ipv6RejectIndex)
        let tunInbound = try XCTUnwrap((mergedRoot["inbounds"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tun" })
        XCTAssertTrue((tunInbound["route_exclude_address"] as? [String])?.contains("203.0.113.10/32") == true)
        let mergedOutbounds = try XCTUnwrap(mergedRoot["outbounds"] as? [[String: Any]])
        let mergedProxy = try XCTUnwrap(mergedOutbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(mergedProxy["type"] as? String, "hysteria2")
        XCTAssertEqual(mergedProxy["server"] as? String, "203.0.113.10")

        try assertSingBoxCheckPasses(json: merged)
    }

    func testSingBoxConfigUsesModernFormat() throws {
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(TestServers.hysteria2[0]))
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
        try assertSingBoxCheckPasses(json: json)
    }

    func testApiBypassGeositeInjectsDnsAndRuleSet() throws {
        let bypass = [
            ApiBypassRuleSet(
                tag: "geoip-ru",
                url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
            ),
            ApiBypassRuleSet(
                tag: "geosite-category-ru",
                url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"
            ),
        ]
        let plan = SingBoxConnectPlan.hysteria2(TestServers.hysteria2[0], bypassRuleSets: bypass)
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: plan)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])

        XCTAssertFalse(json.contains("route_exclude_address_set"))
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, 1)
        XCTAssertEqual(ruleSets[0]["tag"] as? String, "geosite-category-ru")
        XCTAssertEqual(ruleSets[0]["download_detour"] as? String, "proxy")
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.contains { ($0["rule_set"] as? [String])?.contains("geoip-ru") == true })
        XCTAssertFalse(rules.contains { ($0["rule_set"] as? [String])?.contains("geosite-category-ru") == true })

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let dnsServers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let direct = try XCTUnwrap(dnsServers.first { ($0["tag"] as? String) == "dns-direct" })
        XCTAssertEqual(direct["type"] as? String, "udp")
        XCTAssertEqual(direct["server"] as? String, "1.1.1.1")
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains {
            ($0["rule_set"] as? [String]) == ["geosite-category-ru"]
                && ($0["server"] as? String) == "dns-direct"
        })

        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tun" })
        XCTAssertTrue((tun["route_exclude_address"] as? [String])?.contains("1.1.1.1/32") == true)
    }

    func testSiteBypassHostsKeepLocalDnsWithoutGeosite() throws {
        let plan = SingBoxConnectPlan.hysteria2(TestServers.hysteria2[0])
        let json = try SingBoxConfigBuilder.buildTunConfigJson(
            plan: plan,
            bypassHosts: ["instagram.com", "tiktok.com"],
            bypassExcludeIPs: ["203.0.113.50", "203.0.113.51"]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let dnsServers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let direct = try XCTUnwrap(dnsServers.first { ($0["tag"] as? String) == "dns-direct" })
        XCTAssertEqual(direct["type"] as? String, "local")
        XCTAssertNil(direct["server"])
        XCTAssertEqual(dns["reverse_mapping"] as? Bool, true)

        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains {
            ($0["domain_suffix"] as? [String]) == ["instagram.com", "tiktok.com"]
                && ($0["server"] as? String) == "dns-direct"
        })

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        // Apple NE: no domain_suffix → outbound:direct (ENETUNREACH inside full tunnel).
        XCTAssertFalse(rules.contains {
            ($0["domain_suffix"] as? [String]) != nil
                && ($0["outbound"] as? String) == "direct"
        })

        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tun" })
        let excludes = try XCTUnwrap(tun["route_exclude_address"] as? [String])
        XCTAssertTrue(excludes.contains("203.0.113.50/32"))
        XCTAssertTrue(excludes.contains("203.0.113.51/32"))
        XCTAssertFalse(excludes.contains("1.1.1.1/32"))

        try assertSingBoxCheckPasses(json: json)
    }

    func testClashApiExternalController() throws {
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: .hysteria2(TestServers.hysteria2[0]))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let clash = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clash["external_controller"] as? String, "127.0.0.1:19090")
        XCTAssertEqual((experimental["cache_file"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    func testClashTrafficParse() {
        let sample = ClashTraffic.parse("{\"up\":1024,\"down\":2048}")
        XCTAssertEqual(sample?.up, 1024)
        XCTAssertEqual(sample?.down, 2048)
        XCTAssertNil(ClashTraffic.parse("not-json"))
        XCTAssertNil(ClashTraffic.parse("{}"))
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
        #if os(macOS)
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
        #else
        _ = json
        #endif
    }
}
