import Foundation

struct Hysteria2Profile: Equatable, Hashable, Sendable {
    let displayName: String
    let city: String?
    let server: String
    let port: Int
    let password: String
    let tlsServerName: String
    let alpn: [String]
    let obfsPassword: String?

    init(
        displayName: String,
        city: String? = nil,
        server: String,
        port: Int,
        password: String,
        tlsServerName: String,
        alpn: [String] = ["h3"],
        obfsPassword: String? = nil
    ) {
        self.displayName = displayName
        self.city = city
        self.server = server
        self.port = port
        self.password = password
        self.tlsServerName = tlsServerName
        self.alpn = alpn.isEmpty ? ["h3"] : alpn
        self.obfsPassword = obfsPassword
    }
}
