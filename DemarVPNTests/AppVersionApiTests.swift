import XCTest
@testable import Demar_Proxy

final class AppVersionApiTests: XCTestCase {
    func testParseResponse() throws {
        let info = try AppVersionApi.parseResponse([
            "version": "1.0.6 (51)",
            "buildNumber": "51",
        ])
        XCTAssertEqual(info.version, "1.0.6 (51)")
        XCTAssertEqual(info.buildNumber, "51")
    }

    func testParseResponseRejectsMissingFields() {
        XCTAssertThrowsError(try AppVersionApi.parseResponse(["buildNumber": "51"]))
        XCTAssertThrowsError(try AppVersionApi.parseResponse(["version": "1.0.6 (51)"]))
    }

    func testIsNewerComparesOnlyBuild() {
        let info = AppVersionInfo(version: "0.0.1 (51)", buildNumber: "51")
        XCTAssertTrue(info.isNewer(thanInstalledBuild: "50"))
        XCTAssertFalse(info.isNewer(thanInstalledBuild: "51"))
        XCTAssertFalse(info.isNewer(thanInstalledBuild: "52"))
    }

    func testIsNewerRejectsInvalidBuilds() {
        XCTAssertFalse(AppVersionInfo(version: "1.0.6", buildNumber: "abc").isNewer(thanInstalledBuild: "50"))
        XCTAssertFalse(AppVersionInfo(version: "1.0.6", buildNumber: "51").isNewer(thanInstalledBuild: "abc"))
    }
}
