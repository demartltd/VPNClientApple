import Foundation

enum ProxyProfile: Equatable, Hashable, Sendable {
    case hysteria2(Hysteria2Profile)
    case trojan(TrojanProfile)
    case vlessReality(VlessRealityProfile)

    var displayName: String {
        switch self {
        case .hysteria2(let p): p.displayName
        case .trojan(let p): p.displayName
        case .vlessReality(let p): p.displayName
        }
    }

    var hasCredentials: Bool {
        switch self {
        case .hysteria2(let p): p.hasCredentials
        case .trojan(let p): p.hasCredentials
        case .vlessReality(let p): p.hasCredentials
        }
    }

    var serverProtocol: ServerProtocol {
        switch self {
        case .hysteria2: .hysteria2
        case .trojan: .trojan
        case .vlessReality: .vlessReality
        }
    }

    func toConnectPlan(bypassRuleSets: [ApiBypassRuleSet] = []) -> SingBoxConnectPlan {
        switch self {
        case .hysteria2(let p): .hysteria2(p, bypassRuleSets: bypassRuleSets)
        case .trojan(let p): .trojan(p, bypassRuleSets: bypassRuleSets)
        case .vlessReality(let p): .vlessReality(p, bypassRuleSets: bypassRuleSets)
        }
    }
}
