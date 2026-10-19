import Foundation

struct TrojanProfile: Equatable, Hashable, Sendable {
    let displayName: String
    let server: String
    let port: Int
    let password: String
    let tlsServerName: String

    var hasCredentials: Bool { !password.isEmpty }
}
