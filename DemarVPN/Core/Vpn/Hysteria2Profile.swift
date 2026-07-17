import Foundation

struct Hysteria2Profile: Equatable, Hashable, Sendable {
    let displayName: String
    let city: String?
    let server: String
    let port: Int
    let password: String
    let tlsServerName: String

    init(
        displayName: String,
        city: String? = nil,
        server: String,
        port: Int,
        password: String,
        tlsServerName: String
    ) {
        self.displayName = displayName
        self.city = city
        self.server = server
        self.port = port
        self.password = password
        self.tlsServerName = tlsServerName
    }
}
