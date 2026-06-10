import XCTest
@testable import DemarVPN

final class DefaultInterfaceReporterTests: XCTestCase {
    private let en0 = DefaultInterfaceUpdate(name: "en0", index: 14, isExpensive: false, isConstrained: false)
    private let en1 = DefaultInterfaceUpdate(name: "en1", index: 15, isExpensive: false, isConstrained: false)

    func testReportsFirstInterfaceAndDedupesRepeats() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(en0), .ignore)
        XCTAssertEqual(filter.decide(en1), .report(en1))
    }

    func testReportsExpensiveChangeOnSameInterface() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        var expensive = en0
        expensive.isExpensive = true
        XCTAssertEqual(filter.decide(expensive), .report(expensive))
    }

    func testLossIsDebouncedNotReportedImmediately() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(.lost), .scheduleLoss)
        XCTAssertEqual(filter.decide(.lost), .ignore)
        XCTAssertEqual(filter.confirmLoss(), .lost)
        XCTAssertEqual(filter.decide(.lost), .ignore)
    }

    func testRecoveryCancelsPendingLoss() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(.lost), .scheduleLoss)
        XCTAssertEqual(filter.decide(en0), .ignore)
        XCTAssertNil(filter.confirmLoss())
    }

    func testRecoveryWithNewInterfaceAfterPendingLossIsReported() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(.lost), .scheduleLoss)
        XCTAssertEqual(filter.decide(en1), .report(en1))
        XCTAssertNil(filter.confirmLoss())
    }

    func testInterfaceReportedAgainAfterConfirmedLoss() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(.lost), .scheduleLoss)
        XCTAssertEqual(filter.confirmLoss(), .lost)
        XCTAssertEqual(filter.decide(en0), .report(en0))
    }
}
