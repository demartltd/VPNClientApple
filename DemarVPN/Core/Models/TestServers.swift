import Foundation

enum TestServers {
    static let hysteria2: [Hysteria2Profile] = [
        Hysteria2Profile(
            displayName: "FI-FREE-89",
            server: "fi-f-1.xyzdeer.space",
            port: 8443,
            password: "REDACTED",
            tlsServerName: "fi-f-1.xyzdeer.space"
        ),
        Hysteria2Profile(
            displayName: "NL-PLUS-42",
            city: "Amsterdam",
            server: "nl-f-1.xyzdeer.space",
            port: 8443,
            password: "REDACTED",
            tlsServerName: "nl-f-1.xyzdeer.space"
        ),
    ]

    static var profiles: [ServerProfile] {
        hysteria2.map { ServerProfile(profile: .hysteria2($0)) }
    }
}
