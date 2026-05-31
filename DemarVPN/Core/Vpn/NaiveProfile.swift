import Foundation

struct NaiveProfile: Equatable, Hashable, Sendable {
    let displayName: String
    let server: String
    let port: Int
    let username: String
    let password: String
    let tlsServerName: String
}
