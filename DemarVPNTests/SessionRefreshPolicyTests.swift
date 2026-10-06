import XCTest
@testable import Demar_Proxy

final class SessionRefreshPolicyTests: XCTestCase {
    func testNilIsStale() {
        XCTAssertTrue(SessionRefreshPolicy.isStale(since: nil))
    }

    func testFreshWithinTTL() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last = now.addingTimeInterval(-599)
        XCTAssertFalse(SessionRefreshPolicy.isStale(since: last, now: now))
    }

    func testStaleAtTTL() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last = now.addingTimeInterval(-600)
        XCTAssertTrue(SessionRefreshPolicy.isStale(since: last, now: now))
    }

    func testStaleBeyondTTL() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last = now.addingTimeInterval(-900)
        XCTAssertTrue(SessionRefreshPolicy.isStale(since: last, now: now))
    }

    func testFailureCooldownWhenNoSuccess() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let attempt = now.addingTimeInterval(-30)
        XCTAssertTrue(SessionRefreshPolicy.inFailureCooldown(success: nil, attempt: attempt, now: now))
        XCTAssertFalse(SessionRefreshPolicy.inFailureCooldown(
            success: nil,
            attempt: now.addingTimeInterval(-91),
            now: now
        ))
    }

    func testFailureCooldownClearsAfterSuccess() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let attempt = now.addingTimeInterval(-10)
        let success = now.addingTimeInterval(-5)
        XCTAssertFalse(SessionRefreshPolicy.inFailureCooldown(success: success, attempt: attempt, now: now))
    }
}
