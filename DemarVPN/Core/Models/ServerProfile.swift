import Foundation

struct NaiveProfile: Equatable, Hashable, Sendable {
    let displayName: String
    let server: String
    let port: Int
    let username: String
    let password: String
    let tlsServerName: String
}

struct ServerProfile: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case vless(String)
        case naive(NaiveProfile)
    }

    let id: String
    let displayName: String
    let kind: Kind

    var listTitle: String {
        switch kind {
        case let .vless(uri): uri
        case let .naive(p): "\(p.server):\(p.port)"
        }
    }

    var listSubtitle: String {
        switch kind {
        case .vless: "VLESS (test)"
        case .naive: "Naive (test)"
        }
    }

    init(vless uri: String) {
        kind = .vless(uri)
        id = uri
        displayName = Self.displayName(from: uri, fallback: "VLESS")
    }

    init(naive profile: NaiveProfile) {
        kind = .naive(profile)
        id = "naive:\(profile.displayName)"
        displayName = profile.displayName
    }

    private static func displayName(from uri: String, fallback: String) -> String {
        guard let fragmentRange = uri.range(of: "#") else { return fallback }
        let raw = String(uri[fragmentRange.upperBound...])
        guard !raw.isEmpty else { return fallback }
        return raw.removingPercentEncoding ?? raw
    }
}
