import Foundation
@testable import Demar_Proxy

enum TestServers {
    static let hysteria2: [Hysteria2Profile] = [
        Hysteria2Profile(
            displayName: "FI-TEST-1",
            server: "fi.example.test",
            port: 8443,
            password: "hy2-dev",
            tlsServerName: "fi.example.test"
        ),
        Hysteria2Profile(
            displayName: "NL-TEST-1",
            city: "Amsterdam",
            server: "nl.example.test",
            port: 8443,
            password: "hy2-dev",
            tlsServerName: "nl.example.test"
        ),
    ]

    static var profiles: [ServerProfile] {
        hysteria2.map { ServerProfile(profile: .hysteria2($0)) }
    }
}
