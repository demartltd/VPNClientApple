import Foundation

enum ServerTier: String, CaseIterable, Equatable, Hashable, Sendable {
    case free = "FREE"
    case dev = "DEV"
    case tester = "TESTER"
    case plus = "PLUS"
    case vip = "VIP"

    var label: String { rawValue }

    static func fromTag(_ tag: String) -> Self {
        let mid = tag.split(separator: "-").dropFirst().first.map(String.init)?.uppercased() ?? ""
        return Self(rawValue: mid) ?? .free
    }
}

enum ServerProtocol: String, CaseIterable, Equatable, Hashable, Sendable {
    case hysteria2 = "HY2"
    case trojan = "Trojan"
    case vlessReality = "VLESS"
    /// OpenFlux SOCKS sidecar — UI «White» / «White List».
    case openflux = "White"

    var apiKey: String {
        switch self {
        case .hysteria2: "hysteria2"
        case .trojan: "trojan"
        case .vlessReality: "vless_reality"
        case .openflux: "openflux"
        }
    }

    /// Short list badge: HY2 / TRJ / VLESS / White.
    var label: String {
        switch self {
        case .hysteria2: "HY2"
        case .trojan: "TRJ"
        case .vlessReality: "VLESS"
        case .openflux: "White"
        }
    }

    var fullLabel: String {
        switch self {
        case .hysteria2: "Hysteria2"
        case .trojan: "Trojan"
        case .vlessReality: "VLESS Reality"
        case .openflux: "White List"
        }
    }

    /// False for OpenFlux — local SOCKS has no meaningful uplink RTT.
    var showsUplinkPing: Bool { self != .openflux }

    /// TUN site groups with `isWhiteList` go through VPN instead of bypass.
    var usesWhiteListVpnMode: Bool { self == .openflux }

    static let socksBadge = "SCK"
    static let socksBadgeFull = "SOCKS"

    static func fromApi(_ raw: String) -> ServerProtocol? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.apiKey == key }
    }
}

/// List/home/details protocol chips. OpenFlux → White List (white) + SOCKS (neutral).
struct ProtocolBadgeSpec: Equatable, Sendable {
    let label: String
    var whiteList: Bool = false
}

struct ServerProfile: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let profile: ProxyProfile
    let city: String?
    let bypassRuleSets: [ApiBypassRuleSet]
    let loadPercent: Int?

    var connectPlan: SingBoxConnectPlan { profile.toConnectPlan(bypassRuleSets: bypassRuleSets) }
    var canConnect: Bool { profile.hasCredentials }
    var isLocked: Bool { !canConnect }
    var serverProtocol: ServerProtocol { profile.serverProtocol }
    var protocolLabel: String { serverProtocol.label }
    var protocolFullLabel: String { serverProtocol.fullLabel }
    var tier: ServerTier { .fromTag(displayName) }

    var uplinkPort: UInt16 { UInt16(clamping: profile.dialPort) }

    func protocolBadges(full: Bool = false) -> [ProtocolBadgeSpec] {
        switch serverProtocol {
        case .openflux:
            return [
                ProtocolBadgeSpec(label: full ? protocolFullLabel : protocolLabel, whiteList: true),
                ProtocolBadgeSpec(label: full ? ServerProtocol.socksBadgeFull : ServerProtocol.socksBadge),
            ]
        default:
            return [ProtocolBadgeSpec(label: full ? protocolFullLabel : protocolLabel)]
        }
    }

    var effectiveLoadPercent: Int { (loadPercent ?? 10).clamped(to: 0...100) }

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

    /// List/home primary name: country or raw tag.
    var titleName: String {
        if let countryName, !countryName.isEmpty { return countryName }
        return displayName
    }

    var listSubtitle: String {
        guard let city, !city.isEmpty, let tagNumber else { return "" }
        return "\(city) #\(tagNumber)"
    }

    var flagEmoji: String { Self.flagEmoji(forCountryCode: countryCode ?? "") }

    /// ISO 3166-1 alpha-2 → regional-indicator emoji (empty if invalid).
    static func flagEmoji(forCountryCode code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2 else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in upper.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90,
                  let regional = UnicodeScalar(127397 + scalar.value)
            else { return "" }
            scalars.append(regional)
        }
        return String(scalars)
    }

    init(
        profile: ProxyProfile,
        id: String? = nil,
        city: String? = nil,
        bypassRuleSets: [ApiBypassRuleSet] = [],
        loadPercent: Int? = nil
    ) {
        self.profile = profile
        self.id = id ?? "\(profile.serverProtocol.apiKey):\(profile.displayName)"
        displayName = profile.displayName
        self.city = city ?? {
            if case .hysteria2(let hy2) = profile { return hy2.city }
            return nil
        }()
        self.bypassRuleSets = bypassRuleSets.uniquedByTag()
        self.loadPercent = loadPercent
    }
}

extension Array where Element == ServerProfile {
    /// §9: only badges present in the list.
    func visibleTiers() -> [ServerTier] {
        ServerTier.allCases.filter { tier in contains { $0.tier == tier } }
    }

    func visibleProtocols() -> [ServerProtocol] {
        ServerProtocol.allCases.filter { proto in contains { $0.serverProtocol == proto } }
    }

    func matchesFilters(tiers: Set<ServerTier>, protocols: Set<ServerProtocol>) -> Bool {
        isEmpty || contains { tiers.contains($0.tier) && protocols.contains($0.serverProtocol) }
    }

    /// Unlocked first, then locked; favorites on top within group; A–Z.
    func filterServers(
        tiers: Set<ServerTier>,
        protocols: Set<ServerProtocol>,
        favoriteIds: Set<String> = []
    ) -> [ServerProfile] {
        filter { tiers.contains($0.tier) && protocols.contains($0.serverProtocol) }
            .sorted {
                if $0.isLocked != $1.isLocked { return !$0.isLocked && $1.isLocked }
                let f0 = favoriteIds.contains($0.id)
                let f1 = favoriteIds.contains($1.id)
                if f0 != f1 { return f0 && !f1 }
                return $0.displayName < $1.displayName
            }
    }

    /// Prefer unlocked current/last; never stick on locked preview after downgrade.
    func pickSelected(currentId: String?, lastId: String?) -> ServerProfile? {
        let unlocked = filter { !$0.isLocked }
        return unlocked.first(where: { $0.id == currentId })
            ?? unlocked.first(where: { $0.id == lastId })
            ?? unlocked.first
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
