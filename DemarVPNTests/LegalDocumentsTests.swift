import XCTest
@testable import Demar_Proxy

final class LegalDocumentsTests: XCTestCase {
    func testDocumentURLs() {
        XCTAssertEqual(
            LegalDocument.terms.url.absoluteString,
            "https://raw.githubusercontent.com/demartltd/tos-pp/refs/heads/main/ToS.md"
        )
        XCTAssertEqual(
            LegalDocument.privacy.url.absoluteString,
            "https://raw.githubusercontent.com/demartltd/tos-pp/refs/heads/main/pp.md"
        )
    }

    func testDecodeAcceptsUTF8Body() throws {
        let data = Data("# Terms\n\nHello".utf8)
        let response = HTTPURLResponse(
            url: LegalDocument.terms.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        XCTAssertEqual(try LegalDocumentLoader.decode(data: data, response: response), "# Terms\n\nHello")
    }

    func testDecodeRejectsNon200() {
        let response = HTTPURLResponse(
            url: LegalDocument.privacy.url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!
        XCTAssertThrowsError(try LegalDocumentLoader.decode(data: Data("# x".utf8), response: response)) { error in
            XCTAssertEqual(error as? LegalDocumentError, .badStatus(404))
        }
    }

    func testDecodeRejectsEmpty() {
        let response = HTTPURLResponse(
            url: LegalDocument.terms.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        XCTAssertThrowsError(try LegalDocumentLoader.decode(data: Data("   \n".utf8), response: response)) { error in
            XCTAssertEqual(error as? LegalDocumentError, .emptyOrInvalid)
        }
    }

    func testDecodeRejectsNonUTF8() {
        let response = HTTPURLResponse(
            url: LegalDocument.terms.url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        // Isolated invalid UTF-8 sequence.
        XCTAssertThrowsError(try LegalDocumentLoader.decode(data: Data([0xFF, 0xFE]), response: response)) { error in
            XCTAssertEqual(error as? LegalDocumentError, .emptyOrInvalid)
        }
    }
}
