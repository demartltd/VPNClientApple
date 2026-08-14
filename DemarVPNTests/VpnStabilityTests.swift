import XCTest
@testable import Demar_Proxy

final class VpnStabilityTests: XCTestCase {
    func testSharedLineFileAppendsWithoutImmediateCompaction() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-linefile-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        try VpnSharedLineFile.appendLine("one", to: url, maxLines: 512)
        try VpnSharedLineFile.appendLine("two", to: url, maxLines: 512)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "one\ntwo\n")
    }

    func testSharedLineFileCompactsWhenOverSizeBudget() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demar-linefile-compact-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        // Compaction triggers only after >16KB; use large lines so the ring stays at maxLines.
        let maxLines = 4
        for index in 0..<12 {
            let payload = String(repeating: "x", count: 5_000) + "-\(index)"
            try VpnSharedLineFile.appendLine(payload, to: url, maxLines: maxLines)
        }

        let lines = try VpnSharedLineFile.readTrimmedLines(from: url)
        XCTAssertLessThanOrEqual(lines.count, maxLines)
        XCTAssertTrue(lines.last?.hasSuffix("-11") == true)
    }

    func testReconfigurePolicyDoesNotSoftRestartOnWake() {
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "wake"))
        XCTAssertFalse(VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathChanged"))
        XCTAssertTrue(
            VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: "pathRecoveredAfterLoss")
        )
    }

    func testPathLossPolicyIgnoresUnsatisfiedWhenPhysPresent() {
        XCTAssertFalse(
            TunnelPathLossPolicy.shouldArmRecoveryAfterUnsatisfied(physicalInterfacesEmpty: false)
        )
        XCTAssertTrue(
            TunnelPathLossPolicy.shouldArmRecoveryAfterUnsatisfied(physicalInterfacesEmpty: true)
        )
    }

    func testReadinessFailsOnFailedHeartbeat() {
        XCTAssertEqual(
            VpnTunnelReadiness.failureMessage(heartbeat: "failed-22", startFailure: nil),
            "VPN tunnel start failed (failed-22)."
        )
        XCTAssertEqual(
            VpnTunnelReadiness.failureMessage(heartbeat: "core-started", startFailure: "boom"),
            "boom"
        )
        XCTAssertNil(VpnTunnelReadiness.failureMessage(heartbeat: "core-started", startFailure: nil))
        XCTAssertNil(VpnTunnelReadiness.failureMessage(heartbeat: "running", startFailure: ""))
    }

    func testMergeDirectIPsKeepsPinnedLiteralServer() throws {
        let plan = SingBoxConnectPlan.hysteria2(TestServers.hysteria2[0]).pinEndpoint(to: ["203.0.113.10"])
        let json = try SingBoxConfigBuilder.buildTunConfigJson(plan: plan)
        let merged = try SingBoxConfigBuilder.mergeDirectIPs(
            ["198.51.100.7", "203.0.113.10"],
            into: json,
            dialTag: SingBoxConfigConstants.proxyTag
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(merged.data(using: .utf8))) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxy["type"] as? String, "hysteria2")
        XCTAssertEqual(proxy["server"] as? String, "203.0.113.10")
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tun" })
        let excludes = try XCTUnwrap(tun["route_exclude_address"] as? [String])
        XCTAssertTrue(excludes.contains("198.51.100.7/32"))
        XCTAssertTrue(excludes.contains("203.0.113.10/32"))
    }

    func testControlStateSkipIdenticalWrite() throws {
        // Best-effort: App Group may be unavailable in some CI simulators.
        guard (try? VpnSharedStore.vpnDirectoryURL()) != nil else {
            throw XCTSkip("App Group container unavailable in this test environment")
        }
        VpnSharedStore.saveControlState("disconnected", notify: false)
        let before = try Data(contentsOf: VpnSharedStore.stateURL())
        VpnSharedStore.saveControlState("disconnected", notify: false)
        let after = try Data(contentsOf: VpnSharedStore.stateURL())
        XCTAssertEqual(before, after)
    }
}

@MainActor
final class VpnStabilityMainActorTests: XCTestCase {
    func testAppLogBatchAppendInvalidatesPanelTextLazily() {
        let log = AppLog(includeStartupLine: false)
        log.append(contentsOf: ["[vpn] a", "[vpn] a", "[vpn] b"])
        XCTAssertEqual(log.lines.count, 2)
        let snapshot = log.panelText
        XCTAssertTrue(snapshot.contains("[vpn] a"))
        XCTAssertTrue(snapshot.contains("[vpn] b"))
        XCTAssertEqual(log.panelText, snapshot)
    }

    func testAppLogKeepsBoundedRing() {
        let log = AppLog(includeStartupLine: false)
        let total = VpnSharedStore.journalMaxLines + 80
        log.append(contentsOf: (0..<total).map { "[test] n-\($0)" })
        XCTAssertEqual(log.lines.count, VpnSharedStore.journalMaxLines)
        let text = log.panelText
        XCTAssertTrue(text.contains("n-\(total - 1)"))
        XCTAssertFalse(text.contains("n-0\n") || text.hasPrefix("n-0"))
    }
}
