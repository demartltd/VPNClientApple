import XCTest
@testable import DemarVPN

final class DemarHttpControlHostTests: XCTestCase {
    func testControlHostsMatchApiSurface() {
        XCTAssertTrue(DemarHttp.isControlHost("auth.example.invalid"))
        XCTAssertTrue(DemarHttp.isControlHost("vpn.example.invalid"))
        XCTAssertTrue(DemarHttp.isControlHost("account.example.invalid"))
        XCTAssertTrue(DemarHttp.isControlHost("API.demar.cc"))
        XCTAssertFalse(DemarHttp.isControlHost("demar.cc"))
        XCTAssertFalse(DemarHttp.isControlHost("github.com"))
    }
}
