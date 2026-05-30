import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SingBoxConfigBuilder {
    private static let tunInboundTag = "demar-tun"
    private static let preflightInboundTag = "demar-preflight"

    static func buildTunConfigJson(
        profile: VlessProfile,
        tunName: String = "utun0",
        mtu: Int = 1492,
        logLevel: String = "warning",
        autoOutboundsInterface: String? = nil // kept for API compatibility; ignored by sing-box.
    ) throws -> String {
        try SingBoxCompatibilityValidator.validate(profile: profile)
        let config = buildTunConfig(
            proxyOutbound: vlessOutbound(for: profile),
            directIPs: directIPs(for: profile),
            tunName: tunName,
            mtu: mtu,
            logLevel: logLevel
        )
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SingBoxConfigBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode sing-box config JSON.",
            ])
        }
        return json
    }

    static func buildTunConfigJson(
        profile: NaiveProfile,
        tunName: String = "utun0",
        mtu: Int = 1492,
        logLevel: String = "warning"
    ) throws -> String {
        let config = buildTunConfig(
            proxyOutbound: naiveOutbound(for: profile),
            directIPs: directIPs(for: profile),
            tunName: tunName,
            mtu: mtu,
            logLevel: "info",
            dnsFinal: "dns-remote",
            routeResolveServer: "dns-remote",
            dnsBootstrapDomains: [profile.tlsServerName],
            strictRoute: true,
            directDomains: [profile.tlsServerName]
        )
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SingBoxConfigBuilder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode sing-box config JSON.",
            ])
        }
        return json
    }

    static func buildPreflightTestJson(
        profile: VlessProfile,
        logLevel: String = "warning"
    ) throws -> String {
        try SingBoxCompatibilityValidator.validate(profile: profile)
        var config = buildTunConfig(
            proxyOutbound: vlessOutbound(for: profile),
            directIPs: directIPs(for: profile),
            tunName: "utun0",
            mtu: 1492,
            logLevel: logLevel
        )
        config["inbounds"] = [[
            "tag": preflightInboundTag,
            "type": "mixed",
            "listen": "127.0.0.1",
            "listen_port": 37179,
        ]]
        config["route"] = route(for: preflightInboundTag, directIPs: directIPs(for: profile))
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SingBoxConfigBuilder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode preflight config JSON.",
            ])
        }
        return json
    }

    private static func buildTunConfig(
        proxyOutbound: [String: Any],
        directIPs: [String],
        tunName: String,
        mtu: Int,
        logLevel: String,
        dnsFinal: String = "dns-remote",
        routeResolveServer: String = "dns-direct",
        dnsBootstrapDomains: [String] = [],
        rejectQuicOverTun: Bool = false,
        rejectPublicDoH: Bool = false,
        strictRoute: Bool = true,
        directDomains: [String] = []
    ) -> [String: Any] {
        #if os(iOS)
        let effectiveMtu = min(mtu, 1400)
        #else
        let effectiveMtu = mtu
        #endif
        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": tunInboundTag,
            "interface_name": tunName,
            "mtu": effectiveMtu,
            "auto_route": true,
            "strict_route": strictRoute,
            "address": ["172.19.0.1/30"],
        ]
        #if os(iOS)
        tunInbound["stack"] = "gvisor"
        if !directIPs.isEmpty {
            tunInbound["route_address"] = ["0.0.0.0/1", "128.0.0.0/1"]
            tunInbound["route_exclude_address"] = directIPs.map { "\($0)/32" }
        }
        #elseif os(macOS)
        tunInbound["stack"] = "system"
        #endif

        return [
            "log": ["level": logLevel],
            "dns": dns(final: dnsFinal, bootstrapDomains: dnsBootstrapDomains),
            "inbounds": [tunInbound],
            "route": route(
                for: tunInboundTag,
                directIPs: directIPs,
                directDomains: directDomains,
                resolveServer: routeResolveServer,
                rejectQuicOverTun: rejectQuicOverTun,
                rejectPublicDoH: rejectPublicDoH
            ),
            "outbounds": [
                proxyOutbound,
                ["type": "direct", "tag": "direct"],
            ],
        ]
    }

    private static func directIPs(for profile: VlessProfile) -> [String] {
        isIPv4Literal(profile.serverAddress) ? [profile.serverAddress] : []
    }

    private static func directIPs(for profile: NaiveProfile) -> [String] {
        isIPv4Literal(profile.server) ? [profile.server] : []
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private static func domainResolver(server: String = "dns-direct") -> [String: Any] {
        ["server": server, "strategy": "ipv4_only"]
    }

    private static func dns(final dnsFinal: String, bootstrapDomains: [String] = []) -> [String: Any] {
        var rules: [[String: Any]] = []
        for domain in bootstrapDomains where !domain.isEmpty {
            rules.append(["domain": [domain], "server": "dns-direct"])
        }
        return [
            "servers": [
                [
                    "type": "udp",
                    "tag": "dns-direct",
                    "server": "1.1.1.1",
                ],
                [
                    "type": "udp",
                    "tag": "dns-remote",
                    "server": "1.1.1.1",
                    "detour": "proxy",
                ],
            ],
            "rules": rules,
            "final": dnsFinal,
            "strategy": "ipv4_only",
        ]
    }

    private static func vlessOutbound(for profile: VlessProfile) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": profile.serverAddress,
            "server_port": profile.serverPort,
            "uuid": profile.userId,
            "network": profile.network,
            "domain_resolver": domainResolver(),
        ]
        if let flow = profile.flow, !flow.isEmpty { outbound["flow"] = flow }
        if let tls = SingBoxStreamSettings.tlsBlock(for: profile) { outbound["tls"] = tls }
        if let transport = SingBoxStreamSettings.transportBlock(for: profile) { outbound["transport"] = transport }
        if let packetEncoding = profile.query["packetencoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !packetEncoding.isEmpty
        {
            outbound["packet_encoding"] = packetEncoding
        }
        return outbound
    }

    private static func naiveOutbound(for profile: NaiveProfile) -> [String: Any] {
        [
            "type": "naive",
            "tag": "proxy",
            "server": profile.server,
            "server_port": profile.port,
            "username": profile.username,
            "password": profile.password,
            "domain_resolver": domainResolver(server: "dns-remote"),
            "insecure_concurrency": 1,
            "udp_over_tcp": ["enabled": true],
            "quic": false,
            "tls": [
                "enabled": true,
                "server_name": profile.tlsServerName,
            ],
        ]
    }

    private static let publicDoHResolverCIDRs = [
        "1.1.1.1/32", "1.0.0.1/32", "8.8.8.8/32", "8.8.4.4/32",
        "2606:4700:4700::1111/128", "2606:4700:4700::1001/128",
        "2001:4860:4860::8888/128", "2001:4860:4860::8844/128",
    ]

    private static func route(
        for inboundTag: String,
        directIPs: [String],
        directDomains: [String] = [],
        resolveServer: String = "dns-direct",
        rejectQuicOverTun: Bool = false,
        rejectPublicDoH: Bool = false
    ) -> [String: Any] {
        var rules: [[String: Any]] = [[
            "inbound": [inboundTag],
            "action": "resolve",
            "server": resolveServer,
            "strategy": "ipv4_only",
        ], [
            "inbound": [inboundTag],
            "action": "sniff",
        ], [
            "protocol": "dns",
            "action": "hijack-dns",
        ], [
            "ip_is_private": true,
            "action": "route",
            "outbound": "direct",
        ]]
        for ip in directIPs {
            rules.append([
                "ip_cidr": ["\(ip)/32"],
                "action": "route",
                "outbound": "direct",
            ])
        }
        for domain in directDomains where !domain.isEmpty {
            rules.append([
                "domain": [domain],
                "action": "route",
                "outbound": "direct",
            ])
        }
        if rejectPublicDoH {
            rules.append([
                "ip_cidr": publicDoHResolverCIDRs,
                "port": [443, 853],
                "action": "reject",
            ])
        }
        if rejectQuicOverTun {
            rules.append([
                "network": "udp",
                "port": 443,
                "action": "reject",
            ])
            rules.append([
                "port": 853,
                "action": "reject",
            ])
        }
        rules.append([
            "ip_version": 6,
            "action": "reject",
        ])
        rules.append([
            "inbound": [inboundTag],
            "action": "route",
            "outbound": "proxy",
        ])
        return [
            "auto_detect_interface": true,
            "default_domain_resolver": domainResolver(),
            "final": "proxy",
            "rules": rules,
        ]
    }
}

enum SingBoxCompatibilityValidator {
    enum CompatibilityError: LocalizedError {
        case unsupportedNetwork(String)
        case unsupportedEncryption(String)
        case unsupportedParameter(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedNetwork(name):
                "Sing-box does not support VLESS transport: \(name)."
            case let .unsupportedEncryption(value):
                "Sing-box VLESS does not support encryption=\(value). Use encryption=none."
            case let .unsupportedParameter(name):
                "Sing-box profile rejects unsupported parameter: \(name)."
            }
        }
    }

    static func validate(profile: VlessProfile) throws {
        let supportedNetworks: Set<String> = ["tcp", "ws", "grpc", "httpupgrade", "http", "quic"]
        if !supportedNetworks.contains(profile.network) {
            throw CompatibilityError.unsupportedNetwork(profile.network)
        }
        let encryption = profile.encryption.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !encryption.isEmpty, encryption != "none" {
            throw CompatibilityError.unsupportedEncryption(profile.encryption)
        }
        let rejectedParams = ["pqv", "spx", "extra", "mode", "x_padding_bytes", "xpaddingbytes"]
        for key in rejectedParams {
            if let value = profile.query[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                throw CompatibilityError.unsupportedParameter(key)
            }
        }
        if let headerType = profile.query["headertype"]?.lowercased(),
           !headerType.isEmpty, headerType != "none"
        {
            throw CompatibilityError.unsupportedParameter("headertype")
        }
        if profile.query["kcpseed"] != nil || profile.network == "kcp" || profile.network == "hysteria" {
            throw CompatibilityError.unsupportedNetwork(profile.network)
        }
        if profile.security == "none" || profile.security.isEmpty {
            throw CompatibilityError.unsupportedParameter("security")
        }
    }
}
