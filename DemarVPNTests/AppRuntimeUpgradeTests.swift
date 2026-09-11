import XCTest
@testable import Demar_Proxy

final class AppRuntimeUpgradeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppRuntimeUpgradeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstInstallDoesNotUpgrade() {
        var wiped = false
        let upgraded = AppRuntimeUpgrade.consumeIfUpgraded(
            defaults: defaults,
            token: "1|v1.13.14",
            onUpgrade: { wiped = true }
        )
        XCTAssertFalse(upgraded)
        XCTAssertFalse(wiped)
    }

    func testSameTokenDoesNotUpgrade() {
        _ = AppRuntimeUpgrade.consumeIfUpgraded(defaults: defaults, token: "1|v1.13.14", onUpgrade: {})
        var wiped = false
        let upgraded = AppRuntimeUpgrade.consumeIfUpgraded(
            defaults: defaults,
            token: "1|v1.13.14",
            onUpgrade: { wiped = true }
        )
        XCTAssertFalse(upgraded)
        XCTAssertFalse(wiped)
    }

    func testBuildBumpUpgradesOnce() {
        _ = AppRuntimeUpgrade.consumeIfUpgraded(defaults: defaults, token: "1|v1.13.14", onUpgrade: {})
        var wipeCount = 0
        let first = AppRuntimeUpgrade.consumeIfUpgraded(
            defaults: defaults,
            token: "2|v1.13.14",
            onUpgrade: { wipeCount += 1 }
        )
        let second = AppRuntimeUpgrade.consumeIfUpgraded(
            defaults: defaults,
            token: "2|v1.13.14",
            onUpgrade: { wipeCount += 1 }
        )
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(wipeCount, 1)
    }

    func testCoreBumpUpgrades() {
        _ = AppRuntimeUpgrade.consumeIfUpgraded(defaults: defaults, token: "1|v1.13.14", onUpgrade: {})
        var wiped = false
        let upgraded = AppRuntimeUpgrade.consumeIfUpgraded(
            defaults: defaults,
            token: "1|v1.13.15",
            onUpgrade: { wiped = true }
        )
        XCTAssertTrue(upgraded)
        XCTAssertTrue(wiped)
    }
}
