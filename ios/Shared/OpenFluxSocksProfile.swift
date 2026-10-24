import Foundation

struct OpenFluxSocksProfile: Equatable, Hashable, Sendable {
    let displayName: String
    let openfluxLink: String
    let socksHost: String
    let socksPort: Int

    var server: String { Self.normalizedEndpoint(host: socksHost, port: socksPort).0 }
    var port: Int { Self.normalizedEndpoint(host: socksHost, port: socksPort).1 }
    var hasCredentials: Bool { !openfluxLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(
        displayName: String,
        openfluxLink: String,
        socksHost: String = defaultSocksHost,
        socksPort: Int = defaultSocksPort
    ) {
        self.displayName = displayName
        self.openfluxLink = openfluxLink
        self.socksHost = socksHost
        self.socksPort = socksPort
    }

    static let defaultSocksHost = LoopbackPortWait.defaultSocksHost
    static let defaultSocksPort = LoopbackPortWait.defaultSocksPort
    static let engine = "openflux_socks"

    static func normalizedEndpoint(host: String, port: Int) -> (String, Int) {
        LoopbackPortWait.normalizedSocks(host: host, port: port)
    }
}
