import Foundation

struct ServerProfile: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case naive(NaiveProfile)
    }

    let id: String
    let displayName: String
    let kind: Kind

    var connectPlan: SingBoxConnectPlan {
        switch kind {
        case let .naive(profile): .naive(profile)
        }
    }

    var listTitle: String {
        switch kind {
        case let .naive(p): "\(p.server):\(p.port)"
        }
    }

    var listSubtitle: String {
        switch kind {
        case .naive: "Naive (test)"
        }
    }

    init(naive profile: NaiveProfile) {
        kind = .naive(profile)
        id = "naive:\(profile.displayName)"
        displayName = profile.displayName
    }
}
