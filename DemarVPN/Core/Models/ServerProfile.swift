import Foundation

enum ServerTier: String, CaseIterable, Equatable, Hashable, Sendable {
    case free = "FREE"
    case dev = "DEV"
    case plus = "PLUS"
    case vip = "VIP"

    var label: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .dev: "Dev"
        case .plus: "Plus"
        case .vip: "Vip"
        }
    }

    static func fromTag(_ tag: String) -> Self {
        let mid = tag.split(separator: "-").dropFirst().first.map(String.init)?.uppercased() ?? ""
        return Self(rawValue: mid) ?? .free
    }
}

enum ServerProtocol: String, CaseIterable, Equatable, Hashable, Sendable {
    case naive = "Naive"
    case hysteria2 = "Hysteria2"
}

struct ServerProfile: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
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

    var serverProtocol: ServerProtocol {
        switch kind {
        case .naive: .naive
        case .hysteria2: .hysteria2
        }
    }

    var tier: ServerTier { .fromTag(displayName) }

    var tagNumber: Int? {
        Int(displayName.split(separator: "-").last ?? "")
    }

    var countryCode: String? {
        let code = displayName.split(separator: "-").first.map(String.init)?.uppercased() ?? ""
        return code.count == 2 && code.allSatisfy(\.isLetter) ? code : nil
    }

    var countryName: String? {
        guard let countryCode else { return nil }
        return Locale.current.localizedString(forRegionCode: countryCode)
    }

    var city: String? {
        switch kind {
        case let .naive(profile): profile.city
        case let .hysteria2(profile): profile.city
        }
    }

    var listTitle: String {
        guard let countryName, !countryName.isEmpty else { return displayName }
        return "\(countryName) | \(tier.label)"
    }

    var listSubtitle: String {
        guard let city, !city.isEmpty, let tagNumber else { return "" }
        return "\(city) #\(tagNumber)"
    }

    var flagEmoji: String {
        guard let countryCode else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in countryCode.unicodeScalars {
            guard let regional = UnicodeScalar(127397 + scalar.value) else { return "" }
            scalars.append(regional)
        }
        return String(scalars)
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
}

extension Array where Element == ServerProfile {
    func visibleTiers() -> [ServerTier] {
        ServerTier.allCases.filter { $0 != .dev || contains { $0.tier == .dev } }
    }

    func filterServers(protocol: ServerProtocol, tier: ServerTier?) -> [ServerProfile] {
        lazy
            .filter { $0.serverProtocol == `protocol` }
            .filter { tier == nil || $0.tier == tier }
            .sorted { $0.displayName < $1.displayName }
    }
}
