import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct SingBoxTunOptions {
    var dnsFinal: String
    var dnsBootstrapDomains: [String]
    var directDomains: [String]
    var strictRoute: Bool
    var blockQUIC: Bool
}

struct SingBoxConnectPlan {
    let uplinkHost: String
    let proxyOutbound: [String: Any]
    let directIPs: [String]
    let tun: SingBoxTunOptions

    func pinEndpoint(to addresses: [String]) -> SingBoxConnectPlan {
        guard let selected = addresses.first else { return self }
        var outbound = proxyOutbound
        outbound["server"] = selected
        return SingBoxConnectPlan(
            uplinkHost: uplinkHost,
            proxyOutbound: outbound,
            directIPs: Array(Set(directIPs + addresses)).sorted(),
            tun: tun
        )
    }

    static func naive(_ profile: NaiveProfile) -> SingBoxConnectPlan {
        var outbound: [String: Any] = [
            "type": "naive",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
            "connect_timeout": "10s",
            "domain_resolver": SingBoxDnsBuilder.domainResolver(server: SingBoxConfigConstants.dnsDirectTag),
            "udp_over_tcp": ["enabled": true, "version": 2],
            "quic": false,
            "tls": [
                "enabled": true,
                "server_name": profile.tlsServerName,
            ],
        ]
        if !profile.username.isEmpty { outbound["username"] = profile.username }
        if !profile.password.isEmpty { outbound["password"] = profile.password }
        return plan(
            uplink: profile.server,
            outbound: outbound,
            tlsServerName: profile.tlsServerName,
            blockQUIC: true
        )
    }

    static func hysteria2(_ profile: Hysteria2Profile) -> SingBoxConnectPlan {
        let outbound: [String: Any] = [
            "type": "hysteria2",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
            "password": profile.password,
            "domain_resolver": SingBoxDnsBuilder.domainResolver(server: SingBoxConfigConstants.dnsDirectTag),
            "tls": [
                "enabled": true,
                "server_name": profile.tlsServerName,
                "alpn": ["h3"],
            ],
        ]
        return plan(
            uplink: profile.server,
            outbound: outbound,
            tlsServerName: profile.tlsServerName,
            blockQUIC: false
        )
    }

    private static func plan(
        uplink: String,
        outbound: [String: Any],
        tlsServerName: String,
        blockQUIC: Bool
    ) -> SingBoxConnectPlan {
        SingBoxConnectPlan(
            uplinkHost: uplink,
            proxyOutbound: outbound,
            directIPs: directIPs(forHost: uplink),
            tun: SingBoxTunOptions(
                dnsFinal: SingBoxConfigConstants.dnsRemoteTag,
                dnsBootstrapDomains: Array(Set([tlsServerName, uplink])).sorted(),
                directDomains: Array(Set([tlsServerName, uplink])).sorted(),
                strictRoute: true,
                blockQUIC: blockQUIC
            )
        )
    }

    private static func directIPs(forHost host: String) -> [String] {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return [] }
        return [host]
    }
}
