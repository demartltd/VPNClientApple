import XCTest
@testable import DemarVPN

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
