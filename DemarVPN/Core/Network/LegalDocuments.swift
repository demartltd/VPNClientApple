import Foundation
import os

enum LegalDocument: String, CaseIterable, Identifiable, Hashable {
    case terms
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: String(localized: "Terms of use")
        case .privacy: String(localized: "Privacy")
        }
    }

    var subtitle: String {
        switch self {
        case .terms: String(localized: "Service usage rules")
        case .privacy: String(localized: "How data is handled")
        }
    }

    var systemImage: String {
        switch self {
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        }
    }

    var url: URL {
        switch self {
        case .terms:
            URL(string: "https://raw.githubusercontent.com/demartltd/tos-pp/refs/heads/main/ToS.md")!
        case .privacy:
            URL(string: "https://raw.githubusercontent.com/demartltd/tos-pp/refs/heads/main/pp.md")!
        }
    }

    func fetchMarkdown() async throws -> String {
        try await LegalDocumentLoader.load(self)
    }
}

enum LegalDocumentLoader {
    private static let cache = OSAllocatedUnfairLock<[LegalDocument: String]>(initialState: [:])

    static func load(_ document: LegalDocument) async throws -> String {
        if let hit = cache.withLock({ $0[document] }) { return hit }
        let md = try await fetch(from: document.url)
        cache.withLock { $0[document] = md }
        return md
    }

    static func clearCache() {
        cache.withLock { $0.removeAll() }
    }

    /// Visible for tests.
    static func seedCache(_ document: LegalDocument, _ md: String) {
        cache.withLock { $0[document] = md }
    }

    static func fetch(from url: URL) async throws -> String {
        let data: Data
        do {
            data = try await DemarHttp.getData(
                url,
                accept: "text/plain, text/markdown, */*",
                media: false
            )
        } catch let e as DemarAPIError where e.statusCode > 0 {
            throw LegalDocumentError.badStatus(e.statusCode)
        } catch {
            throw LegalDocumentError.badStatus(0)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return try decode(data: data, response: response)
    }

    /// Pure helper for unit tests — no network.
    static func decode(data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LegalDocumentError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            throw LegalDocumentError.emptyOrInvalid
        }
        return text
    }
}

enum LegalDocumentError: Error, LocalizedError, Equatable {
    case badStatus(Int)
    case emptyOrInvalid

    var errorDescription: String? {
        switch self {
        case .badStatus: String(localized: "Couldn’t load the document")
        case .emptyOrInvalid: String(localized: "Document is empty or corrupted")
        }
    }
}
