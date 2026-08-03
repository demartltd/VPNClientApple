import Foundation

/// Remote binary rule-set from API `clientConfigJson.route.rule_set`.
struct ApiBypassRuleSet: Equatable, Hashable, Sendable {
    let tag: String
    let url: String

    var isGeosite: Bool { tag.hasPrefix("geosite") }
    var isGeoip: Bool { tag.hasPrefix("geoip") }
}
