import Foundation

struct ServerProfile: Identifiable, Equatable, Hashable {
    let id: String
    let uri: String
    let displayName: String

    init(uri: String) {
        self.uri = uri
        self.id = uri
        self.displayName = Self.displayName(from: uri)
    }

    private static func displayName(from uri: String) -> String {
        guard let fragmentRange = uri.range(of: "#") else { return "VLESS" }
        let raw = String(uri[fragmentRange.upperBound...])
        guard !raw.isEmpty else { return "VLESS" }
        return raw.removingPercentEncoding ?? raw
    }
}
