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

    static func naive(_ profile: NaiveProfile) -> SingBoxConnectPlan {
        var outbound: [String: Any] = [
            "type": "naive",
            "tag": SingBoxConfigConstants.proxyTag,
            "server": profile.server,
            "server_port": profile.port,
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

        return SingBoxConnectPlan(
            uplinkHost: profile.server,
            proxyOutbound: outbound,
            directIPs: directIPs(forHost: profile.server),
            tun: SingBoxTunOptions(
                dnsFinal: SingBoxConfigConstants.dnsRemoteTag,
                dnsBootstrapDomains: [profile.tlsServerName],
                directDomains: [profile.tlsServerName],
                strictRoute: true
            )
        )
    }

    private static func directIPs(forHost host: String) -> [String] {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return [] }
        return [host]
    }
}
