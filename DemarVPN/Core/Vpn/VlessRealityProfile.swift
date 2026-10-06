import Foundation

struct VlessRealityProfile: Equatable, Hashable, Sendable {
    let displayName: String
    let server: String
    let port: Int
    let uuid: String
    let tlsServerName: String
    let publicKey: String
    let shortId: String
    let flow: String?

    var hasCredentials: Bool {
        !uuid.isEmpty && !publicKey.isEmpty && !shortId.isEmpty
    }
}
