import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct SingBoxTunOptions {
    var dnsFinal: String
    var dnsBootstrapDomains: [String]
    var directDomains: [String]
    var strictRoute: Bool
}

struct SingBoxConnectPlan {
    let uplinkHost: String
    let proxyOutbound: [String: Any]
    let directIPs: [String]
    let tun: SingBoxTunOptions
    let bypassRuleSets: [ApiBypassRuleSet]

    var geoipBypassTags: [String] {
        bypassRuleSets.filter(\.isGeoip).map(\.tag)
    }

    func pinEndpoint(to addresses: [String]) -> SingBoxConnectPlan {
        guard let selected = addresses.first else { return self }
        var outbound = proxyOutbound
        outbound["server"] = selected
        return SingBoxConnectPlan(
            uplinkHost: selected,
            proxyOutbound: outbound,
            directIPs: Array(Set(directIPs + addresses)).sorted(),
            tun: tun,
            bypassRuleSets: bypassRuleSets
        )
    }

    static func hysteria2(
        _ profile: Hysteria2Profile,
        bypassRuleSets: [ApiBypassRuleSet] = []
    ) -> SingBoxConnectPlan {
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": profile.tlsServerName,
        ]
        if !profile.alpn.isEmpty { tls["alpn"] = profile.alpn }
        var outbound: [String: Any] = [
            "type": "hysteria2",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
            "password": profile.password,
            "udp_fragment": true,
            "domain_resolver": SingBoxDnsBuilder.domainResolver(server: SingBoxConfigConstants.dnsDirectTag),
            "tls": tls,
        ]
        if let obfs = profile.obfsPassword, !obfs.isEmpty {
            outbound["obfs"] = ["type": "salamander", "password": obfs]
        }
        return SingBoxConnectPlan(
            uplinkHost: profile.server,
            proxyOutbound: outbound,
            directIPs: directIPs(forHost: profile.server),
            tun: SingBoxTunOptions(
                dnsFinal: SingBoxConfigConstants.dnsRemoteTag,
                dnsBootstrapDomains: Array(Set([profile.tlsServerName, profile.server])).sorted(),
                directDomains: Array(Set([profile.tlsServerName, profile.server])).sorted(),
                strictRoute: false
            ),
            bypassRuleSets: bypassRuleSets.uniquedByTag()
        )
    }

    private static func directIPs(forHost host: String) -> [String] {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return [] }
        return [host]
    }
}

extension Array where Element == ApiBypassRuleSet {
    func uniquedByTag() -> [ApiBypassRuleSet] {
        var seen = Set<String>()
        return filter { seen.insert($0.tag).inserted }
    }
}
