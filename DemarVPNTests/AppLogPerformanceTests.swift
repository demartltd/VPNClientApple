import XCTest
@testable import DemarVPN

@MainActor
final class AppLogPerformanceTests: XCTestCase {
    func testBatchAppendDeduplicatesWithSingleSnapshot() {
        let log = AppLog(includeStartupLine: false)

        log.append(contentsOf: [
            "[vpn] connected",
            "[vpn] connected",
            "[vpn] route active",
        ])

        XCTAssertEqual(log.lines.count, 2)
        XCTAssertEqual(log.panelText, log.lines.map(\.text).joined(separator: "\n"))
    }

    func testBatchAppendKeepsBoundedNewestEntries() {
        let log = AppLog(includeStartupLine: false)
        log.append(contentsOf: (0..<(VpnSharedStore.journalMaxLines + 50)).map { "[test] event-\($0)" })

        XCTAssertEqual(log.lines.count, VpnSharedStore.journalMaxLines)
        XCTAssertTrue(log.panelText.contains("event-\(VpnSharedStore.journalMaxLines + 49)"))
        XCTAssertFalse(log.panelText.contains("event-0\n"))
    }

    func testPanelTextIsLazyUntilRead() {
        let log = AppLog(includeStartupLine: false)
        log.append("[vpn] first")
        log.append("[vpn] second")
        // Accessing lines should not require panel materialization; panelText rebuilds once.
        XCTAssertEqual(log.lines.count, 2)
        let text = log.panelText
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }
}
