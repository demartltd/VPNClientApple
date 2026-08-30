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
}
