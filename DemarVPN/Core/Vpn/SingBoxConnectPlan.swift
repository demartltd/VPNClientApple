import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct SingBoxTunOptions {
    var dnsFinal: String
    /// Domains for DNS bootstrap → dns-direct and route → direct.
    var uplinkDomains: [String]
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

    func withBypassRuleSets(_ sets: [ApiBypassRuleSet]) -> SingBoxConnectPlan {
        SingBoxConnectPlan(
            uplinkHost: uplinkHost,
            proxyOutbound: proxyOutbound,
            directIPs: directIPs,
            tun: tun,
            bypassRuleSets: sets.uniquedByTag()
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
        // Hysteria CC: floor tiny API values so uploads are not throttled to a few Mbps.
        if let up = profile.upMbps { outbound["up_mbps"] = max(up, 10) }
        if let down = profile.downMbps { outbound["down_mbps"] = max(down, 10) }
        return of(
            uplink: profile.server,
            outbound: outbound,
            domains: bootstrapDomains(server: profile.server, tlsServerName: profile.tlsServerName),
            bypass: bypassRuleSets
        )
    }

    static func trojan(
        _ profile: TrojanProfile,
        bypassRuleSets: [ApiBypassRuleSet] = []
    ) -> SingBoxConnectPlan {
        let outbound: [String: Any] = [
            "type": "trojan",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
            "password": profile.password,
            "tls": ["enabled": true, "server_name": profile.tlsServerName],
            "multiplex": ["enabled": true],
            "domain_resolver": SingBoxDnsBuilder.domainResolver(server: SingBoxConfigConstants.dnsDirectTag),
        ]
        return of(
            uplink: profile.server,
            outbound: outbound,
            domains: bootstrapDomains(server: profile.server, tlsServerName: profile.tlsServerName),
            bypass: bypassRuleSets
        )
    }

    static func vlessReality(
        _ profile: VlessRealityProfile,
        bypassRuleSets: [ApiBypassRuleSet] = []
    ) -> SingBoxConnectPlan {
        // Mirror Android: bootstrap = uplink host only; no network/mux (Vision = TCP command).
        // https://sing-box.sagernet.org/configuration/outbound/vless/
        let domains = isHostname(profile.server) ? [profile.server.trimmingCharacters(in: .whitespacesAndNewlines)] : []
        let flow = profile.flow?.trimmingCharacters(in: .whitespacesAndNewlines)
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
            "uuid": profile.uuid,
            "tls": [
                "enabled": true,
                "server_name": profile.tlsServerName,
                "utls": ["enabled": true, "fingerprint": "chrome"],
                "reality": [
                    "enabled": true,
                    "public_key": profile.publicKey,
                    "short_id": profile.shortId,
                ],
            ],
            "domain_resolver": SingBoxDnsBuilder.domainResolver(server: SingBoxConfigConstants.dnsDirectTag),
        ]
        if let flow, !flow.isEmpty { outbound["flow"] = flow }
        return of(uplink: profile.server, outbound: outbound, domains: domains, bypass: bypassRuleSets)
    }

    /// Local OpenFlux SOCKS sidecar; carrier domains stay outside TUN (anti-loop via bypassHosts).
    static func openfluxSocks(
        _ profile: OpenFluxSocksProfile,
        bypassRuleSets: [ApiBypassRuleSet] = []
    ) -> SingBoxConnectPlan {
        let outbound: [String: Any] = [
            "type": "socks",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
            "version": "5",
        ]
        return SingBoxConnectPlan(
            uplinkHost: profile.server,
            proxyOutbound: outbound,
            directIPs: [],
            tun: SingBoxTunOptions(
                dnsFinal: SingBoxConfigConstants.dnsRemoteTag,
                uplinkDomains: []
            ),
            bypassRuleSets: bypassRuleSets.uniquedByTag()
        )
    }

    /// Carrier roots kept outside TUN (domain_suffix → dns-direct + NE exclude).
    static let openfluxAntiLoopDomains: [String] = [
        "boards.yandex.ru", "yandex.ru", "yandex.net",
    ]

    private static func of(
        uplink: String,
        outbound: [String: Any],
        domains: [String],
        bypass: [ApiBypassRuleSet]
    ) -> SingBoxConnectPlan {
        SingBoxConnectPlan(
            uplinkHost: uplink,
            proxyOutbound: outbound,
            directIPs: directIPs(forHost: uplink),
            tun: SingBoxTunOptions(
                dnsFinal: SingBoxConfigConstants.dnsRemoteTag,
                uplinkDomains: domains
            ),
            bypassRuleSets: bypass.uniquedByTag()
        )
    }

    private static func bootstrapDomains(server: String, tlsServerName: String) -> [String] {
        var domains = Set<String>()
        let sni = tlsServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sni.isEmpty { domains.insert(sni) }
        if isHostname(server) {
            domains.insert(server.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return domains.sorted()
    }

    private static func isHostname(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return directIPs(forHost: trimmed).isEmpty
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
