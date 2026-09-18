import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SingBoxConfigBuilder {
    static func buildTunConfigJson(
        plan: SingBoxConnectPlan,
        tunName: String = "utun0",
        mtu: Int = 4064,
        logLevel: String = "info",
        bypassHosts: [String] = [],
        bypassExcludeIPs: [String] = []
    ) throws -> String {
        try SingBoxConfigEncoding.encodeConfigToJson(
            buildTunConfig(
                plan: plan,
                tunName: tunName,
                mtu: mtu,
                logLevel: logLevel,
                bypassHosts: bypassHosts,
                bypassExcludeIPs: bypassExcludeIPs
            ),
            errorCode: 1,
            description: "Failed to encode sing-box config JSON."
        )
    }

    /// Injects runtime-resolved uplink IPv4 into route bypass and TUN exclude rules.
    static func mergeDirectIPs(
        _ ips: [String],
        into configJson: String,
        dialTag: String = SingBoxConfigConstants.proxyTag
    ) throws -> String {
        let merged = Array(Set(ips.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !merged.isEmpty else { return configJson }
        guard let data = configJson.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return configJson }

        if var inbounds = root["inbounds"] as? [[String: Any]] {
            for index in inbounds.indices where (inbounds[index]["type"] as? String) == "tun" {
                var tun = inbounds[index]
                var exclude = Set((tun["route_exclude_address"] as? [String]) ?? [])
                merged.forEach { exclude.insert(asCIDR32($0)) }
                tun["route_exclude_address"] = exclude.sorted()
                if tun["route_address"] == nil {
                    tun["route_address"] = SingBoxConfigConstants.ipv4SplitRoutes
                }
                inbounds[index] = tun
                break
            }
            root["inbounds"] = inbounds
        }

        if var route = root["route"] as? [String: Any], var rules = route["rules"] as? [[String: Any]] {
            var existing = Set(rules.flatMap { ($0["ip_cidr"] as? [String]) ?? [] })
            let insertAt = rules.firstIndex { ($0["ip_version"] as? Int) == 6 } ?? rules.count
            for ip in merged {
                let cidr = asCIDR32(ip)
                guard !existing.contains(cidr) else { continue }
                rules.insert([
                    "ip_cidr": [cidr],
                    "action": "route",
                    "outbound": SingBoxConfigConstants.directTag,
                ], at: insertAt)
                existing.insert(cidr)
            }
            route["rules"] = rules
            root["route"] = route
        }
        if var outbounds = root["outbounds"] as? [[String: Any]],
           let dialIndex = outbounds.firstIndex(where: { ($0["tag"] as? String) == dialTag })
        {
            let current = (outbounds[dialIndex]["server"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var literal = in_addr()
            let alreadyPinned = !current.isEmpty
                && current.withCString({ inet_pton(AF_INET, $0, &literal) }) == 1
            if !alreadyPinned {
                outbounds[dialIndex]["server"] = merged[0]
                root["outbounds"] = outbounds
            }
        }

        return try SingBoxConfigEncoding.encodeConfigToJson(
            root,
            errorCode: 2,
            description: "Failed to encode merged sing-box config JSON."
        )
    }

    private static func buildTunConfig(
        plan: SingBoxConnectPlan,
        tunName: String,
        mtu: Int,
        logLevel: String,
        bypassHosts: [String],
        bypassExcludeIPs: [String]
    ) -> [String: Any] {
        let geosite = plan.bypassRuleSets.filter(\.isGeosite)
        let hosts = cleanedDomains(bypassHosts)
        let uplink = plan.tun.uplinkDomains
        var config: [String: Any] = [
            "log": ["level": logLevel, "timestamp": true],
            "dns": SingBoxDnsBuilder.makeDns(
                final: plan.tun.dnsFinal,
                bootstrapDomains: uplink,
                geositeRuleSets: geosite,
                bypassHosts: hosts
            ),
            "inbounds": [SingBoxTunInboundBuilder.makeTunInbound(
                tunName: tunName,
                mtu: mtu,
                directIPs: plan.directIPs,
                bypassExcludeIPs: bypassExcludeIPs,
                excludeDNSResolver: !geosite.isEmpty
            ), [
                "type": "mixed",
                "tag": SingBoxConfigConstants.diagnosticInboundTag,
                "listen": SingBoxConfigConstants.diagnosticHost,
                "listen_port": SingBoxConfigConstants.diagnosticPort,
            ]],
            // Site hosts: DNS → dns-direct only. Do NOT route → outbound:direct (ENETUNREACH
            // inside Apple NE full tunnel). True bypass = NE excludedRoutes via bypassExcludeIPs.
            "route": SingBoxRouteBuilder.makeRoute(
                inboundTag: SingBoxConfigConstants.tunInboundTag,
                directIPs: plan.directIPs,
                uplinkDomains: uplink,
                geositeRuleSets: geosite
            ),
            "outbounds": [plan.proxyOutbound, ["type": "direct", "tag": SingBoxConfigConstants.directTag]],
            "experimental": [
                "cache_file": ["enabled": true, "store_dns": true],
                "clash_api": [
                    "external_controller":
                        "\(SingBoxConfigConstants.clashApiHost):\(SingBoxConfigConstants.clashApiPort)",
                ],
            ],
        ]
        // 1.14: remote rule-set download via http_clients (download_detour deprecated).
        if !geosite.isEmpty {
            config["http_clients"] = [[
                "tag": SingBoxConfigConstants.httpRuleSetDownloadTag,
                "detour": SingBoxConfigConstants.proxyTag,
            ]]
        }
        return config
    }
}

enum SingBoxConfigConstants {
    static let tunInboundTag = "demar-tun"
    static let proxyTag = "proxy"
    static let directTag = "direct"
    static let dnsDirectTag = "dns-direct"
    static let dnsRemoteTag = "dns-remote"
    static let httpRuleSetDownloadTag = "rs-dl"
    static let diagnosticInboundTag = "diag-in"
    static let diagnosticHost = "127.0.0.1"
    static let diagnosticPort = 10808
    static let clashApiHost = "127.0.0.1"
    static let clashApiPort = 19090
    static let dnsDirectResolver = "1.1.1.1"
    static let ipv4SplitRoutes = ["0.0.0.0/1", "128.0.0.0/1"]
}

enum SingBoxConfigEncoding {
    static func encodeConfigToJson(_ config: [String: Any], errorCode: Int, description: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
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

    static func makeDns(
        final dnsFinal: String,
        bootstrapDomains: [String] = [],
        geositeRuleSets: [ApiBypassRuleSet] = [],
        bypassHosts: [String] = []
    ) -> [String: Any] {
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
        if !bypassHosts.isEmpty {
            rules.append([
                "domain_suffix": bypassHosts,
                "action": "route",
                "server": SingBoxConfigConstants.dnsDirectTag,
            ])
        }
        for rs in geositeRuleSets {
            rules.append([
                "rule_set": [rs.tag],
                "action": "route",
                "server": SingBoxConfigConstants.dnsDirectTag,
            ])
        }
        // UDP 1.1.1.1 + route_exclude only for geosite — site hosts must not flip dns-direct.
        let dnsDirect: [String: Any] = geositeRuleSets.isEmpty
            ? ["type": "local", "tag": SingBoxConfigConstants.dnsDirectTag]
            : [
                "type": "udp",
                "tag": SingBoxConfigConstants.dnsDirectTag,
                "server": SingBoxConfigConstants.dnsDirectResolver,
            ]
        return [
            "servers": [
                dnsDirect,
                [
                    "type": "https",
                    "tag": SingBoxConfigConstants.dnsRemoteTag,
                    "server": SingBoxConfigConstants.dnsDirectResolver,
                    "detour": SingBoxConfigConstants.proxyTag,
                ],
            ],
            "rules": rules,
            "final": dnsFinal,
            "strategy": "ipv4_only",
            // Needed for domain_suffix route (site bypass) without FakeIP — else match is sniff-only.
            "reverse_mapping": true,
            // 1.14: stale-while-revalidate; persist via cache_file.store_dns.
            "optimistic": true,
        ]
    }
}

enum SingBoxRouteBuilder {
    /// IPv4-only TUN (Telegram). Reject UDP/443 with method default — App Store prefers
    /// HTTP/3; QUIC-in-QUIC over Hysteria2 hangs, and bare `reject` blackholes without fallback.
    private static func rejectDefault(_ match: [String: Any]) -> [String: Any] {
        var rule = match
        rule["action"] = "reject"
        rule["method"] = "default"
        return rule
    }

    static func makeRoute(
        inboundTag: String,
        directIPs: [String],
        uplinkDomains: [String] = [],
        geositeRuleSets: [ApiBypassRuleSet] = []
    ) -> [String: Any] {
        var rules: [[String: Any]] = [
            ["inbound": [inboundTag], "action": "sniff", "timeout": "300ms"],
            ["protocol": "dns", "action": "hijack-dns"],
            rejectDefault(["network": ["udp"], "port": [443]]),
            [
                "ip_is_private": true,
                "action": "route",
                "outbound": SingBoxConfigConstants.directTag,
            ],
        ]
        for ip in directIPs {
            rules.append([
                "ip_cidr": [asCIDR32(ip)],
                "action": "route",
                "outbound": SingBoxConfigConstants.directTag,
            ])
        }
        for domain in uplinkDomains {
            guard let cleanDomain = cleanedDomain(domain) else { continue }
            rules.append([
                "domain": [cleanDomain],
                "action": "route",
                "outbound": SingBoxConfigConstants.directTag,
            ])
        }
        rules.append(rejectDefault(["ip_version": 6]))
        rules.append([
            "inbound": [SingBoxConfigConstants.diagnosticInboundTag],
            "action": "route",
            "outbound": SingBoxConfigConstants.proxyTag,
        ])
        rules.append([
            "inbound": [inboundTag],
            "action": "route",
            "outbound": SingBoxConfigConstants.proxyTag,
        ])
        var route: [String: Any] = [
            "auto_detect_interface": true,
            "default_domain_resolver": SingBoxDnsBuilder.domainResolver(),
            "final": SingBoxConfigConstants.proxyTag,
            "rules": rules,
        ]
        if !geositeRuleSets.isEmpty {
            route["default_http_client"] = SingBoxConfigConstants.httpRuleSetDownloadTag
            route["rule_set"] = geositeRuleSets.map { remoteRuleSet($0) }
        }
        return route
    }

    private static func remoteRuleSet(_ rs: ApiBypassRuleSet) -> [String: Any] {
        [
            "tag": rs.tag,
            "type": "remote",
            "format": "binary",
            "url": rs.url,
        ]
    }
}

enum SingBoxTunInboundBuilder {
    /// First Hysteria2 TUN (`9f0c3cc`): IPv4-only, gvisor. `strict_route: false` kept for iOS 26 NE.
    static func makeTunInbound(
        tunName: String,
        mtu: Int,
        directIPs: [String],
        bypassExcludeIPs: [String] = [],
        excludeDNSResolver: Bool = false
    ) -> [String: Any] {
        // Apple NE default (sing-box): 4064. Low 1400 cap starved bulk TCP MSS.
        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": SingBoxConfigConstants.tunInboundTag,
            "interface_name": tunName,
            "mtu": mtu,
            "auto_route": true,
            "strict_route": false,
            "address": ["172.19.0.1/30"],
            "stack": "gvisor",
            "udp_timeout": "5m",
            // 1.14 UDP NAT (endpoint_independent_nat is no-op since 1.11).
            "udp_mapping": "endpoint_independent",
            "udp_filtering": "endpoint_independent",
            "udp_nat_max": 4096,
            "route_address": SingBoxConfigConstants.ipv4SplitRoutes,
        ]
        let exclude = routeExcludeAddresses(
            directIPs: directIPs,
            bypassExcludeIPs: bypassExcludeIPs,
            excludeDNSResolver: excludeDNSResolver
        )
        if !exclude.isEmpty {
            tunInbound["route_exclude_address"] = exclude
        }
        return tunInbound
    }
}

/// Host or bare IP → `/32`; leaves existing CIDR untouched.
private func asCIDR32(_ raw: String) -> String {
    let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.contains("/") ? clean : "\(clean)/32"
}

private func routeExcludeAddresses(
    directIPs: [String],
    bypassExcludeIPs: [String],
    excludeDNSResolver: Bool
) -> [String] {
    var exclude = Set(directIPs.map { asCIDR32($0) })
    for ip in bypassExcludeIPs {
        let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { continue }
        exclude.insert(asCIDR32(clean))
    }
    if excludeDNSResolver {
        exclude.insert(asCIDR32(SingBoxConfigConstants.dnsDirectResolver))
    }
    return exclude.sorted()
}

private func cleanedDomain(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func cleanedDomains(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for item in raw {
        guard let clean = cleanedDomain(item) else { continue }
        let key = clean.lowercased()
        guard seen.insert(key).inserted else { continue }
        out.append(clean)
    }
    return out
}
