import Foundation

enum TestServers {
    static let naive: [NaiveProfile] = [
        NaiveProfile(
            displayName: "backronym.ru",
            server: "193.35.17.5",
            port: 443,
            username: "u_e06786d0488ce48f",
            password: "REDACTED",
            tlsServerName: "backronym.ru"
        ),
    ]

    static var profiles: [ServerProfile] {
        naive.map(ServerProfile.init(naive:))
    }
}
