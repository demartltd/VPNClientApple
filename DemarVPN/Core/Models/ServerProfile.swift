import Foundation

enum ServerTier: String, CaseIterable, Equatable, Hashable, Sendable {
    case free = "FREE"
    case dev = "DEV"
    case tester = "TESTER"
    case plus = "PLUS"
    case vip = "VIP"

    var label: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .dev: "Dev"
        case .tester: "Tester"
        case .plus: "Plus"
        case .vip: "Vip"
        }
    }

    var paywallRank: Int {
        switch self {
        case .free: 0
        case .tester: 1
        case .plus: 2
        case .vip, .dev: 3
        }
    }

    static func subscriptionRank(_ raw: String?) -> Int {
        switch (raw ?? "free").lowercased() {
        case "tester": 1
        case "plus": 2
        case "vip", "dev": 3
        default: 0
        }
    }

    func requiresUpgrade(subscription raw: String?) -> Bool {
        Self.subscriptionRank(raw) < paywallRank
    }

    static func fromTag(_ tag: String) -> Self {
        let mid = tag.split(separator: "-").dropFirst().first.map(String.init)?.uppercased() ?? ""
        return Self(rawValue: mid) ?? .free
    }
}

enum ServerProtocol: String, CaseIterable, Equatable, Hashable, Sendable {
    case hysteria2 = "HY2"
    case trojan = "Trojan"
    case vlessReality = "VLESS"

    var apiKey: String {
        switch self {
        case .hysteria2: "hysteria2"
        case .trojan: "trojan"
        case .vlessReality: "vless_reality"
        }
    }

    static func fromApi(_ raw: String) -> ServerProtocol? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.apiKey == key }
    }
}

struct ServerProfile: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let profile: ProxyProfile
    let city: String?
    let bypassRuleSets: [ApiBypassRuleSet]

    var connectPlan: SingBoxConnectPlan { profile.toConnectPlan(bypassRuleSets: bypassRuleSets) }
    var canConnect: Bool { profile.hasCredentials }
    var serverProtocol: ServerProtocol { profile.serverProtocol }

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

    init(
        profile: ProxyProfile,
        id: String? = nil,
        city: String? = nil,
        bypassRuleSets: [ApiBypassRuleSet] = []
    ) {
        self.profile = profile
        self.id = id ?? "\(profile.serverProtocol.apiKey):\(profile.displayName)"
        displayName = profile.displayName
        self.city = city ?? {
            if case .hysteria2(let hy2) = profile { return hy2.city }
            return nil
        }()
        self.bypassRuleSets = bypassRuleSets.uniquedByTag()
    }
}

extension Array where Element == ServerProfile {
    func visibleTiers() -> [ServerTier] {
        ServerTier.allCases.filter { tier in
            (tier != .dev && tier != .tester) || contains { $0.tier == tier }
        }
    }

    func visibleProtocols() -> [ServerProtocol] {
        ServerProtocol.allCases.filter { proto in
            contains { $0.serverProtocol == proto }
        }
    }

    func filterServers(protocol: ServerProtocol, tier: ServerTier?) -> [ServerProfile] {
        lazy
            .filter { $0.serverProtocol == `protocol` }
            .filter { tier == nil || $0.tier == tier }
            .sorted { $0.displayName < $1.displayName }
    }
}
