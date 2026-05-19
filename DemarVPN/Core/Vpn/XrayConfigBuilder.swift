import Foundation

enum XrayConfigBuilder {
    private static let tunInboundTag = "demar-tun"

    static func buildTunConfigJson(
        profile: VlessRealityProfile,
        tunName: String = "xray0",
        mtu: Int = 1492,
        logLevel: String = "warning",
        autoOutboundsInterface: String? = nil
    ) throws -> String {
        let config = buildTunConfig(
            profile: profile,
            tunName: tunName,
            mtu: mtu,
            logLevel: logLevel,
            autoOutboundsInterface: autoOutboundsInterface
        )
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "XrayConfigBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode Xray config JSON.",
            ])
        }
        return json
    }

    private static func buildTunConfig(
        profile: VlessRealityProfile,
        tunName: String,
        mtu: Int,
        logLevel: String,
        autoOutboundsInterface: String?
    ) -> [String: Any] {
        var tunSettings: [String: Any] = [
            "name": tunName,
            "mtu": mtu,
        ]
        if let iface = autoOutboundsInterface, !iface.isEmpty {
            tunSettings["autoOutboundsInterface"] = iface
        }

        var user: [String: Any] = [
            "id": profile.userId,
            "encryption": "none",
        ]
        if let flow = profile.flow, !flow.isEmpty {
            user["flow"] = flow
        }

        return [
            "log": ["loglevel": logLevel],
            "dns": ["servers": ["1.1.1.1"]],
            "inbounds": [[
                "tag": tunInboundTag,
                "port": 0,
                "protocol": "tun",
                "sniffing": [
                    "enabled": true,
                    "destOverride": ["http", "tls", "quic"],
                ],
                "settings": tunSettings,
            ]],
            "routing": routing(for: tunInboundTag),
            "outbounds": [
                [
                    "protocol": "vless",
                    "settings": [
                        "vnext": [[
                            "address": profile.serverAddress,
                            "port": profile.serverPort,
                            "users": [user],
                        ]],
                    ],
                    "streamSettings": [
                        "network": profile.transport,
                        "security": "reality",
                        "realitySettings": [
                            "fingerprint": profile.fingerprint,
                            "serverName": profile.sni,
                            "publicKey": profile.publicKey,
                            "spiderX": "",
                            "shortId": profile.shortId,
                        ],
                    ],
                    "tag": "proxy",
                ],
                ["protocol": "freedom", "tag": "direct"],
                ["protocol": "blackhole", "tag": "block"],
            ],
        ]
    }

    private static func routing(for inboundTag: String) -> [String: Any] {
        [
            "domainStrategy": "AsIs",
            "rules": [[
                "type": "field",
                "inboundTag": [inboundTag],
                "outboundTag": "proxy",
            ]],
            "final": "direct",
        ]
    }
}
