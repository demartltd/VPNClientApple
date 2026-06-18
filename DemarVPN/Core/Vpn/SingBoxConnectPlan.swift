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
        SingBoxConnectPlan(
            uplinkHost: profile.server,
            proxyOutbound: [
                "type": "naive",
                "tag": SingBoxConfigConstants.proxyTag,
                "server": profile.server,
                "server_port": profile.port,
                "username": profile.username,
                "password": profile.password,
                "domain_resolver": SingBoxDnsBuilder.domainResolver(server: SingBoxConfigConstants.dnsDirectTag),
                "udp_over_tcp": ["enabled": true],
                "quic": false,
                "tls": [
                    "enabled": true,
                    "server_name": profile.tlsServerName,
                ],
            ],
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
