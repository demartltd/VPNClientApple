import Foundation

/// Bypass rule-set tag from API `clientConfigJson.route.rule_set`.
/// Apple: geosite → bundled local `.srs`; geoip → TunBypass cidrs. API `url` is ignored.
struct ApiBypassRuleSet: Equatable, Hashable, Sendable {
    let tag: String

    var isGeosite: Bool { tag.hasPrefix("geosite") }
    var isGeoip: Bool { tag.hasPrefix("geoip") }

    /// ISO country from `geoip-xx` tags (direct / outside VPN).
    var geoipCountryCode: String? {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.hasPrefix("geoip-") else { return nil }
        let code = String(t.dropFirst("geoip-".count)).uppercased()
        return code.count == 2 && code.allSatisfy(\.isLetter) ? code : nil
    }
}

extension Array where Element == ApiBypassRuleSet {
    func directCountryCodes() -> [String] {
        Set(compactMap(\.geoipCountryCode)).sorted()
    }
}
