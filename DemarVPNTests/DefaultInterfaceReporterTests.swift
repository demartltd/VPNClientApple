import XCTest
@testable import DemarVPN

final class DefaultInterfaceReporterTests: XCTestCase {
    private let en0 = DefaultInterfaceUpdate(name: "en0", index: 14, isExpensive: false, isConstrained: false)
    private let en1 = DefaultInterfaceUpdate(name: "en1", index: 15, isExpensive: false, isConstrained: false)
    private let wifi = PhysicalInterfaceCandidate(name: "en0", index: 14, kind: .wifi)
    private let cellular = PhysicalInterfaceCandidate(name: "pdp_ip0", index: 18, kind: .cellular)

    func testReportsFirstInterfaceAndDedupesRepeats() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(en0), .ignore)
        XCTAssertEqual(filter.decide(en1), .report(en1))
    }

    /// Simulates post-capture resume without filter.reset(): identical en0 must stay .ignore
    /// (reset+resend would make libbox kill Hysteria2 QUIC → Telegram broken pipe).
    func testPostCaptureResumeWithoutResetDedupesIdenticalIface() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        // resumeDefaultInterfaceAfterCapture calls update again without reset:
        XCTAssertEqual(filter.decide(en0), .ignore)
        XCTAssertEqual(filter.decide(en0), .ignore)
    }

    /// Live en0 while path is unsatisfied must still be reportable (iOS steady state
    /// after full routes). Loss-only stays gated; resolver already returns en0.
    func testUnsatisfiedPathStillResolvesLivePhysIface() {
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: false,
            usesWifi: true,
            usesCellular: false,
            usesEthernet: false,
            isExpensive: false,
            isConstrained: false
        )
        let update = DefaultInterfaceResolver.resolve(candidates: [wifi], path: path, lastGood: nil)
        XCTAssertFalse(update.isLost)
        XCTAssertEqual(update.name, "en0")
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(update), .report(update))
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

    func testConfirmLossAbortsWhenCandidatesPresent() {
        let filter = DefaultInterfaceReportFilter()
        XCTAssertEqual(filter.decide(en0), .report(en0))
        XCTAssertEqual(filter.decide(.lost), .scheduleLoss)
        XCTAssertNil(filter.confirmLoss(candidatesPresent: true))
        XCTAssertEqual(filter.decide(.lost), .scheduleLoss)
        XCTAssertEqual(filter.confirmLoss(candidatesPresent: false), .lost)
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

    func testPhysicalSelectorUsesCellularEvenWhenWifiIsListedFirst() {
        let selected = PhysicalInterfaceSelector.preferred(
            from: [wifi, cellular],
            usesWifi: false,
            usesCellular: true,
            usesEthernet: false
        )
        XCTAssertEqual(selected, cellular)
    }

    func testPhysicalSelectorFiltersTunnelInterfaces() {
        XCTAssertTrue(PhysicalInterfaceSelector.isTunnelInterface("utun4"))
        XCTAssertTrue(PhysicalInterfaceSelector.isTunnelInterface("lo0"))
        XCTAssertFalse(PhysicalInterfaceSelector.isTunnelInterface("pdp_ip0"))
    }

    func testResolverFallsBackToLastGoodWhenPhysHiddenBehindTunnel() {
        let lastGood = DefaultInterfaceUpdate(name: "en0", index: 14, isExpensive: false, isConstrained: false)
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: true,
            usesWifi: false,
            usesCellular: false,
            usesEthernet: false,
            isExpensive: false,
            isConstrained: false
        )
        let update = DefaultInterfaceResolver.resolve(candidates: [], path: path, lastGood: lastGood)
        XCTAssertEqual(update.name, "en0")
        XCTAssertEqual(update.index, 14)
        XCTAssertFalse(DefaultInterfaceResolver.isLiveCandidate(update, candidates: []))
    }

    func testResolverReportsLiveIfaceDuringTransientUnsatisfied() {
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: false,
            usesWifi: true,
            usesCellular: false,
            usesEthernet: false,
            isExpensive: false,
            isConstrained: false
        )
        let update = DefaultInterfaceResolver.resolve(candidates: [wifi], path: path, lastGood: nil)
        XCTAssertEqual(update.name, "en0")
        XCTAssertTrue(DefaultInterfaceResolver.isLiveCandidate(update, candidates: [wifi]))
    }

    func testResolverReportsLossWhenUnsatisfiedWithoutCandidatesOrLastGood() {
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: false,
            usesWifi: false,
            usesCellular: false,
            usesEthernet: false,
            isExpensive: false,
            isConstrained: false
        )
        XCTAssertEqual(DefaultInterfaceResolver.resolve(candidates: [], path: path, lastGood: nil), .lost)
    }

    func testResolverSticksThroughWifiCellularHandoff() {
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: true,
            usesWifi: false,
            usesCellular: true,
            usesEthernet: false,
            isExpensive: true,
            isConstrained: true
        )
        let update = DefaultInterfaceResolver.resolve(candidates: [wifi, cellular], path: path, lastGood: en0)
        XCTAssertEqual(update.name, "en0")
        XCTAssertEqual(update.index, 14)
        XCTAssertTrue(update.isExpensive)
        XCTAssertTrue(update.isConstrained)
        XCTAssertTrue(DefaultInterfaceResolver.isLiveCandidate(update, candidates: [wifi, cellular]))
    }

    func testResolverSwitchesWhenStickyIfaceLeavesCandidates() {
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: true,
            usesWifi: false,
            usesCellular: true,
            usesEthernet: false,
            isExpensive: true,
            isConstrained: false
        )
        let update = DefaultInterfaceResolver.resolve(candidates: [cellular], path: path, lastGood: en0)
        XCTAssertEqual(update.name, "pdp_ip0")
        XCTAssertTrue(update.isExpensive)
        XCTAssertTrue(DefaultInterfaceResolver.isLiveCandidate(update, candidates: [cellular]))
    }

    func testResolverKeepsLastGoodWhenPhysHiddenBehindTunnelWithSticky() {
        let lastGood = DefaultInterfaceUpdate(name: "en0", index: 14, isExpensive: false, isConstrained: false)
        let path = DefaultInterfaceResolver.PathContext(
            isSatisfied: true,
            usesWifi: false,
            usesCellular: true,
            usesEthernet: false,
            isExpensive: true,
            isConstrained: false
        )
        let update = DefaultInterfaceResolver.resolve(candidates: [], path: path, lastGood: lastGood)
        XCTAssertEqual(update.name, "en0")
        XCTAssertTrue(update.isExpensive)
        XCTAssertFalse(DefaultInterfaceResolver.isLiveCandidate(update, candidates: []))
    }
}
