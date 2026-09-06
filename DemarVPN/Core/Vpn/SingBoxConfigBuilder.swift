import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SingBoxConfigBuilder {
    static func buildTunConfigJson(
        plan: SingBoxConnectPlan,
        tunName: String = "utun0",
        mtu: Int = 1492,
        logLevel: String = "info"
    ) throws -> String {
        let config = buildTunConfig(
            proxyOutbound: plan.proxyOutbound,
            directIPs: plan.directIPs,
            tunName: tunName,
            mtu: mtu,
            logLevel: logLevel,
            dnsFinal: plan.tun.dnsFinal,
            dnsBootstrapDomains: plan.tun.dnsBootstrapDomains,
            directDomains: plan.tun.directDomains,
            bypassRuleSets: plan.bypassRuleSets
        )
        return try SingBoxConfigEncoding.encodeConfigToJson(
            config,
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
                merged.forEach { exclude.insert("\($0)/32") }
                tun["route_exclude_address"] = exclude.sorted()
                if tun["route_address"] == nil {
                    tun["route_address"] = ["0.0.0.0/1", "128.0.0.0/1"]
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
                let cidr = "\(ip)/32"
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
        proxyOutbound: [String: Any],
        directIPs: [String],
        tunName: String,
        mtu: Int,
        logLevel: String,
        dnsFinal: String,
        dnsBootstrapDomains: [String],
        directDomains: [String],
        bypassRuleSets: [ApiBypassRuleSet]
    ) -> [String: Any] {
        let geosite = bypassRuleSets.filter(\.isGeosite)
        return [
            "log": ["level": logLevel, "timestamp": true],
            "dns": SingBoxDnsBuilder.makeDns(
                final: dnsFinal,
                bootstrapDomains: dnsBootstrapDomains,
                geositeRuleSets: geosite
            ),
            "inbounds": [SingBoxTunInboundBuilder.makeTunInbound(
                tunName: tunName,
                mtu: mtu,
                directIPs: directIPs,
                excludeDNSResolver: !geosite.isEmpty
            ), [
                "type": "mixed",
                "tag": SingBoxConfigConstants.diagnosticInboundTag,
                "listen": SingBoxConfigConstants.diagnosticHost,
                "listen_port": SingBoxConfigConstants.diagnosticPort,
            ]],
            "route": SingBoxRouteBuilder.makeRoute(
                inboundTag: SingBoxConfigConstants.tunInboundTag,
                directIPs: directIPs,
                directDomains: directDomains,
                geositeRuleSets: geosite
            ),
            "outbounds": [proxyOutbound, ["type": "direct", "tag": SingBoxConfigConstants.directTag]],
            "experimental": [
                "cache_file": ["enabled": true],
                "clash_api": [
                    "external_controller":
                        "\(SingBoxConfigConstants.clashApiHost):\(SingBoxConfigConstants.clashApiPort)",
                ],
            ],
        ]
    }
}

enum SingBoxConfigConstants {
    static let tunInboundTag = "demar-tun"
    static let proxyTag = "proxy"
    static let directTag = "direct"
    static let dnsDirectTag = "dns-direct"
    static let dnsRemoteTag = "dns-remote"
    static let diagnosticInboundTag = "diag-in"
    static let diagnosticHost = "127.0.0.1"
    static let diagnosticPort = 10808
    static let clashApiHost = "127.0.0.1"
    static let clashApiPort = 19090
    static let dnsDirectResolver = "1.1.1.1"
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

    static func makeDns(
        final dnsFinal: String,
        bootstrapDomains: [String] = [],
        geositeRuleSets: [ApiBypassRuleSet] = []
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
        for rs in geositeRuleSets {
            rules.append([
                "rule_set": [rs.tag],
                "action": "route",
                "server": SingBoxConfigConstants.dnsDirectTag,
            ])
        }
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
        directDomains: [String] = [],
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
            "download_detour": SingBoxConfigConstants.proxyTag,
        ]
    }
}

enum SingBoxTunInboundBuilder {
    /// First Hysteria2 TUN (`9f0c3cc`): IPv4-only, gvisor. `strict_route: false` kept for iOS 26 NE.
    static func makeTunInbound(
        tunName: String,
        mtu: Int,
        directIPs: [String],
        excludeDNSResolver: Bool = false
    ) -> [String: Any] {
        let effectiveMtu = min(mtu, 1400)
        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": SingBoxConfigConstants.tunInboundTag,
            "interface_name": tunName,
            "mtu": effectiveMtu,
            "auto_route": true,
            "strict_route": false,
            "address": ["172.19.0.1/30"],
            "stack": "gvisor",
            "udp_timeout": "5m",
            "endpoint_independent_nat": false,
            "route_address": ["0.0.0.0/1", "128.0.0.0/1"],
        ]
        var exclude = Set(directIPs.map { "\($0)/32" })
        if excludeDNSResolver {
            exclude.insert("\(SingBoxConfigConstants.dnsDirectResolver)/32")
        }
        if !exclude.isEmpty {
            tunInbound["route_exclude_address"] = exclude.sorted()
        }
        return tunInbound
    }
}

private func cleanedDomain(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
