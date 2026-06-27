import Foundation

enum SingBoxConfigBuilder {
    static func buildTunConfigJson(
        plan: SingBoxConnectPlan,
        tunName: String = "utun0",
        mtu: Int = 1492,
        logLevel: String = "warning"
    ) throws -> String {
        let config = buildTunConfig(
            proxyOutbound: plan.proxyOutbound,
            directIPs: plan.directIPs,
            tunName: tunName,
            mtu: mtu,
            logLevel: logLevel,
            dnsFinal: plan.tun.dnsFinal,
            dnsBootstrapDomains: plan.tun.dnsBootstrapDomains,
            strictRoute: plan.tun.strictRoute,
            directDomains: plan.tun.directDomains
        )
        return try SingBoxConfigEncoding.encodeConfigToJson(
            config,
            errorCode: 1,
            description: "Failed to encode sing-box config JSON."
        )
    }

    private static func buildTunConfig(
        proxyOutbound: [String: Any],
        directIPs: [String],
        tunName: String,
        mtu: Int,
        logLevel: String,
        dnsFinal: String,
        dnsBootstrapDomains: [String],
        strictRoute: Bool,
        directDomains: [String]
    ) -> [String: Any] {
        [
            "log": ["level": logLevel, "timestamp": false],
            "dns": SingBoxDnsBuilder.makeDns(final: dnsFinal, bootstrapDomains: dnsBootstrapDomains),
            "inbounds": [SingBoxTunInboundBuilder.makeTunInbound(
                tunName: tunName,
                mtu: mtu,
                directIPs: directIPs,
                strictRoute: strictRoute
            )],
            "route": SingBoxRouteBuilder.makeRoute(
                inboundTag: SingBoxConfigConstants.tunInboundTag,
                directIPs: directIPs,
                directDomains: directDomains
            ),
            "outbounds": [
                proxyOutbound,
                ["type": "direct", "tag": SingBoxConfigConstants.directTag],
            ],
            "experimental": ["cache_file": ["enabled": true]],
        ]
    }
}

enum SingBoxConfigConstants {
    static let tunInboundTag = "demar-tun"
    static let proxyTag = "proxy"
    static let directTag = "direct"
    static let dnsDirectTag = "dns-direct"
    static let dnsRemoteTag = "dns-remote"
}

enum SingBoxConfigEncoding {
    static func encodeConfigToJson(_ config: [String: Any], errorCode: Int, description: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SingBoxConfigBuilder",
                code: errorCode,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
        return json
    }
}

enum SingBoxDnsBuilder {
    static func domainResolver(server: String = SingBoxConfigConstants.dnsDirectTag) -> [String: Any] {
        ["server": server, "strategy": "ipv4_only"]
    }

    static func makeDns(final dnsFinal: String, bootstrapDomains: [String] = []) -> [String: Any] {
        // Drop local reverse lookups (*.in-addr.arpa / _dns-sd._udp floods) instead of
        // dialing a direct resolver that is unreachable inside the macOS Network Extension.
        var rules: [[String: Any]] = [
            ["query_type": ["PTR"], "action": "reject", "method": "drop"],
        ]
        for domain in bootstrapDomains {
            guard let cleanDomain = cleanedDomain(domain) else { continue }
            rules.append([
                "domain": [cleanDomain],
                "action": "route",
                "server": SingBoxConfigConstants.dnsDirectTag,
            ])
        }
        return [
            "servers": [
                ["type": "udp", "tag": SingBoxConfigConstants.dnsDirectTag, "server": "1.1.1.1"],
                // DoH keeps one multiplexed connection through the proxy instead of a
                // new stream per query (raw tcp/udp), which avoids the abort cascade.
                [
                    "type": "https",
                    "tag": SingBoxConfigConstants.dnsRemoteTag,
                    "server": "1.1.1.1",
                    "detour": SingBoxConfigConstants.proxyTag,
                ],
            ],
            "rules": rules,
            "final": dnsFinal,
            "strategy": "ipv4_only",
        ]
    }
}

enum SingBoxRouteBuilder {
    static func makeRoute(
        inboundTag: String,
        directIPs: [String],
        directDomains: [String] = []
    ) -> [String: Any] {
        // No per-connection direct resolve: domains route to the proxy, which resolves
        // them server-side, so the data path never depends on direct DNS.
        var rules: [[String: Any]] = [[
            "inbound": [inboundTag],
            "action": "sniff",
        ], [
            "protocol": "dns",
            "action": "hijack-dns",
        ], [
            // Drop QUIC so apps fall back to TCP, preventing IPv6/UDP leaks and easing
            // the single naive connection.
            "network": ["udp"],
            "port": [443],
            "action": "reject",
        ], [
            "ip_is_private": true,
            "action": "route",
            "outbound": SingBoxConfigConstants.directTag,
        ]]

        for ip in directIPs {
            rules.append([
                "ip_cidr": ["\(ip)/32"],
                "action": "route",
                "outbound": SingBoxConfigConstants.directTag,
            ])
        }
        for domain in directDomains {
            guard let cleanDomain = cleanedDomain(domain) else { continue }
            rules.append([
                "domain": [cleanDomain],
                "action": "route",
                "outbound": SingBoxConfigConstants.directTag,
            ])
        }

        rules.append(["ip_version": 6, "action": "reject"])
        rules.append([
            "inbound": [inboundTag],
            "action": "route",
            "outbound": SingBoxConfigConstants.proxyTag,
        ])
        return [
            "auto_detect_interface": true,
            "default_domain_resolver": SingBoxDnsBuilder.domainResolver(),
            "final": SingBoxConfigConstants.proxyTag,
            "rules": rules,
        ]
    }
}

enum SingBoxTunInboundBuilder {
    static func makeTunInbound(
        tunName: String,
        mtu: Int,
        directIPs: [String],
        strictRoute: Bool
    ) -> [String: Any] {
        let effectiveMtu = min(mtu, 1400)
        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": SingBoxConfigConstants.tunInboundTag,
            "interface_name": tunName,
            "mtu": effectiveMtu,
            "auto_route": true,
            "strict_route": strictRoute,
            "address": ["172.19.0.1/30"],
            "stack": "gvisor",
        ]
        if !directIPs.isEmpty {
            tunInbound["route_address"] = ["0.0.0.0/1", "128.0.0.0/1"]
            tunInbound["route_exclude_address"] = directIPs.map { "\($0)/32" }
        }
        return tunInbound
    }
}

private func cleanedDomain(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
