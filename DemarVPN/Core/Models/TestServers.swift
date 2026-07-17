import Foundation

enum TestServers {
    static let naive: [NaiveProfile] = [
        NaiveProfile(
            displayName: "DE-FREE-93",
            city: "Horka",
            server: "de-f-1.backronym.ru",
            port: 8443,
            username: "u_5f0d9beeab98bf6c",
            password: "REDACTED",
            tlsServerName: "de-f-1.backronym.ru"
        ),
        NaiveProfile(
            displayName: "FI-DEV-99",
            server: "backronym.ru",
            port: 8443,
            username: "u_e06786d0488ce48f",
            password: "REDACTED",
            tlsServerName: "backronym.ru"
        ),
        NaiveProfile(
            displayName: "NL-PLUS-42",
            city: "Amsterdam",
            server: "ne-f-1.backronym.ru",
            port: 8443,
            username: "u_0dd19c46df7fc81a",
            password: "REDACTED",
            tlsServerName: "ne-f-1.backronym.ru"
        ),
        NaiveProfile(
            displayName: "SE-VIP-71",
            city: "Stockholm",
            server: "swe-f-1.backronym.ru",
            port: 8443,
            username: "u_7e870100ee3ef828",
            password: "REDACTED",
            tlsServerName: "swe-f-1.backronym.ru"
        ),
    ]

    static let hysteria2: [Hysteria2Profile] = [
        Hysteria2Profile(
            displayName: "FI-FREE-89",
            server: "fi-f-1.xyzdeer.space",
            port: 8443,
            password: "REDACTED",
            tlsServerName: "fi-f-1.xyzdeer.space"
        ),
    ]

    static var profiles: [ServerProfile] {
        [
            ServerProfile(naive: naive[0]),
            ServerProfile(naive: naive[1]),
            ServerProfile(hysteria2: hysteria2[0]),
            ServerProfile(naive: naive[2]),
            ServerProfile(naive: naive[3]),
        ]
    }
}
