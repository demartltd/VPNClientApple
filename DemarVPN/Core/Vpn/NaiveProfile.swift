import Foundation

struct NaiveProfile: Equatable, Hashable, Sendable {
    let displayName: String
    let city: String?
    let server: String
    let port: Int
    let username: String
    let password: String
    let tlsServerName: String

    init(
        displayName: String,
        city: String? = nil,
        server: String,
        port: Int,
        username: String,
        password: String,
        tlsServerName: String
    ) {
        self.displayName = displayName
        self.city = city
        self.server = server
        self.port = port
        self.username = username
        self.password = password
        self.tlsServerName = tlsServerName
    }
}
