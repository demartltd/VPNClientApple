import Foundation

enum ProxyProfile: Equatable, Hashable, Sendable {
    case hysteria2(Hysteria2Profile)
    case trojan(TrojanProfile)
    case vlessReality(VlessRealityProfile)
    case openflux(OpenFluxSocksProfile)

    var displayName: String {
        switch self {
        case .hysteria2(let p): p.displayName
        case .trojan(let p): p.displayName
        case .vlessReality(let p): p.displayName
        case .openflux(let p): p.displayName
        }
    }

    var hasCredentials: Bool {
        switch self {
        case .hysteria2(let p): p.hasCredentials
        case .trojan(let p): p.hasCredentials
        case .vlessReality(let p): p.hasCredentials
        case .openflux(let p): p.hasCredentials
        }
    }

    var serverProtocol: ServerProtocol {
        switch self {
        case .hysteria2: .hysteria2
        case .trojan: .trojan
        case .vlessReality: .vlessReality
        case .openflux: .openflux
        }
    }

    /// Dial host for uplink probe (not connectPlan.uplinkHost — OFX plan is loopback).
    var dialHost: String {
        switch self {
        case .hysteria2(let p): p.server
        case .trojan(let p): p.server
        case .vlessReality(let p): p.server
        case .openflux(let p): p.server
        }
    }

    var dialPort: Int {
        switch self {
        case .hysteria2(let p): p.port
        case .trojan(let p): p.port
        case .vlessReality(let p): p.port
        case .openflux(let p): p.port
        }
    }

    var openflux: OpenFluxSocksProfile? {
        if case .openflux(let p) = self { p } else { nil }
    }

    func toConnectPlan(bypassRuleSets: [ApiBypassRuleSet] = []) -> SingBoxConnectPlan {
        switch self {
        case .hysteria2(let p): .hysteria2(p, bypassRuleSets: bypassRuleSets)
        case .trojan(let p): .trojan(p, bypassRuleSets: bypassRuleSets)
        case .vlessReality(let p): .vlessReality(p, bypassRuleSets: bypassRuleSets)
        case .openflux(let p): .openfluxSocks(p, bypassRuleSets: bypassRuleSets)
        }
    }
}
