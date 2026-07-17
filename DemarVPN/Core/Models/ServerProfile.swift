import Foundation

struct ServerProfile: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case naive(NaiveProfile)
        case hysteria2(Hysteria2Profile)
    }

    let id: String
    let displayName: String
    let kind: Kind

    var connectPlan: SingBoxConnectPlan {
        switch kind {
        case let .naive(profile): .naive(profile)
        case let .hysteria2(profile): .hysteria2(profile)
        }
    }

    var listSubtitle: String {
        switch kind {
        case let .naive(profile): Self.subtitle(protocolName: "Naive", city: profile.city)
        case let .hysteria2(profile): Self.subtitle(protocolName: "Hysteria2", city: profile.city)
        }
    }

    init(naive profile: NaiveProfile) {
        kind = .naive(profile)
        id = "naive:\(profile.displayName)"
        displayName = profile.displayName
    }

    init(hysteria2 profile: Hysteria2Profile) {
        kind = .hysteria2(profile)
        id = "hysteria2:\(profile.displayName)"
        displayName = profile.displayName
    }

    private static func subtitle(protocolName: String, city: String?) -> String {
        guard let city, !city.isEmpty else { return protocolName }
        return "\(protocolName) · \(city)"
    }
}
