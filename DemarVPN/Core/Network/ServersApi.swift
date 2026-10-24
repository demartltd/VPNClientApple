import Foundation

struct ServersListResult: @unchecked Sendable {
    let vpnSubscription: String?
    let vpnExpiresAt: String?
    let servers: [ServerProfile]
    let trafficExceeded: Bool
    let rawJson: [String: Any]
}

enum ServersApi {
    static func fetchServers(userId: String, loginAt: String) async throws -> ServersListResult {
        let json = try await DemarHttp.vpnPost("vpn/servers", ["userId": userId, "loginAt": loginAt])
        let result = try parseServersResponse(json)
        let rawCount = (json["servers"] as? [[String: Any]])?.count ?? 0
        await MainActor.run {
            AppLog.shared.append("[servers] raw=\(rawCount) parsed=\(result.servers.count)")
        }
        return result
    }

    static func parseServersResponse(_ json: [String: Any]) throws -> ServersListResult {
        let arr = json["servers"] as? [[String: Any]] ?? []
        var profiles: [ServerProfile] = []
        for item in arr {
            if let p = parseServerItem(item) {
                profiles.append(p)
            }
        }
        let rawCount = arr.count
        try validateParsedCount(rawCount: rawCount, parsedCount: profiles.count)
        return ServersListResult(
            vpnSubscription: (json["vpnSubscription"] as? String)?.nilIfBlank,
            vpnExpiresAt: (json["vpnExpiresAt"] as? String)?.nilIfBlank,
            servers: profiles,
            trafficExceeded: json["trafficExceeded"] as? Bool ?? false,
            rawJson: json
        )
    }

    static func validateParsedCount(rawCount: Int, parsedCount: Int) throws {
        if rawCount > 0 && parsedCount == 0 {
            throw DemarAPIError(message: "No supported servers in response", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
    }

    /// Pure helper for unit tests — no network.
    static func parseServerItem(_ item: [String: Any]) -> ServerProfile? {
        guard let id = (item["id"] as? String)?.nilIfBlank,
              let name = (item["name"] as? String)?.nilIfBlank
        else { return nil }
        let city = (item["city"] as? String)?.nilIfBlank
        guard let protocolKind = ServerProtocol.fromApi((item["protocol"] as? String) ?? "") else { return nil }

        if let configRaw = (item["clientConfigJson"] as? String)?.nilIfBlank,
           let configData = configRaw.data(using: .utf8),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        {
            let parsed: ServerProfile? = switch protocolKind {
            case .hysteria2: parseHysteria2(id: id, name: name, city: city, config: config)
            case .trojan: parseTrojan(id: id, name: name, city: city, config: config)
            case .vlessReality: parseVlessReality(id: id, name: name, city: city, config: config)
            case .openflux: parseOpenFlux(id: id, name: name, city: city, config: config)
            }
            if let parsed { return parsed }
        }

        return preview(protocolKind, id: id, name: name, city: city)
    }

    private static func preview(
        _ protocolKind: ServerProtocol,
        id: String,
        name: String,
        city: String?
    ) -> ServerProfile {
        let empty: ProxyProfile = switch protocolKind {
        case .hysteria2:
            .hysteria2(Hysteria2Profile(
                displayName: name,
                city: city,
                server: "preview",
                port: 443,
                password: "",
                tlsServerName: "preview"
            ))
        case .trojan:
            .trojan(TrojanProfile(
                displayName: name,
                server: "",
                port: 443,
                password: "",
                tlsServerName: ""
            ))
        case .vlessReality:
            .vlessReality(VlessRealityProfile(
                displayName: name,
                server: "",
                port: 443,
                uuid: "",
                tlsServerName: "",
                publicKey: "",
                shortId: "",
                flow: nil
            ))
        case .openflux:
            .openflux(OpenFluxSocksProfile(displayName: name, openfluxLink: ""))
        }
        return ServerProfile(profile: empty, id: id, city: city)
    }

    private static func parseOpenFlux(
        id: String,
        name: String,
        city: String?,
        config: [String: Any]
    ) -> ServerProfile? {
        let engine = (config["engine"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard engine == OpenFluxSocksProfile.engine else { return nil }
        guard let link = (config["openfluxLink"] as? String)?.nilIfBlank else { return nil }
        let socks = config["socks"] as? [String: Any]
        let host = (socks?["host"] as? String)?.nilIfBlank ?? OpenFluxSocksProfile.defaultSocksHost
        let port = positivePort(socks?["port"]) ?? OpenFluxSocksProfile.defaultSocksPort
        return ServerProfile(
            profile: .openflux(OpenFluxSocksProfile(
                displayName: name,
                openfluxLink: link,
                socksHost: host,
                socksPort: port
            )),
            id: id,
            city: city,
            bypassRuleSets: parseBypassRuleSets(config)
        )
    }

    private static func parseHysteria2(
        id: String,
        name: String,
        city: String?,
        config: [String: Any]
    ) -> ServerProfile? {
        guard let hy2 = firstOutbound(config, type: "hysteria2"),
              let (server, port) = dialFields(hy2)
        else { return nil }
        let password = (hy2["password"] as? String) ?? ""
        let tls = hy2["tls"] as? [String: Any]
        let tlsName = (tls?["server_name"] as? String)?.nilIfBlank ?? server
        let alpn: [String] = {
            guard let arr = tls?["alpn"] as? [String], !arr.isEmpty else { return ["h3"] }
            return arr.filter { !$0.isEmpty }
        }()
        let obfs = ((hy2["obfs"] as? [String: Any])?["password"] as? String)?.nilIfBlank
        let outboundCity = (hy2["city"] as? String)?.nilIfBlank ?? city
        return ServerProfile(
            profile: .hysteria2(Hysteria2Profile(
                displayName: name,
                city: outboundCity,
                server: server,
                port: port,
                password: password,
                tlsServerName: tlsName,
                alpn: alpn,
                obfsPassword: obfs,
                upMbps: positiveMbps(hy2["up_mbps"]),
                downMbps: positiveMbps(hy2["down_mbps"])
            )),
            id: id,
            city: outboundCity,
            bypassRuleSets: parseBypassRuleSets(config)
        )
    }

    private static func parseTrojan(
        id: String,
        name: String,
        city: String?,
        config: [String: Any]
    ) -> ServerProfile? {
        guard let trojan = firstOutbound(config, type: "trojan"),
              let (server, port) = dialFields(trojan)
        else { return nil }
        let password = (trojan["password"] as? String) ?? ""
        let tls = trojan["tls"] as? [String: Any]
        let tlsName = (tls?["server_name"] as? String)?.nilIfBlank ?? server
        let outboundCity = (trojan["city"] as? String)?.nilIfBlank ?? city
        return ServerProfile(
            profile: .trojan(TrojanProfile(
                displayName: name,
                server: server,
                port: port,
                password: password,
                tlsServerName: tlsName
            )),
            id: id,
            city: outboundCity,
            bypassRuleSets: parseBypassRuleSets(config)
        )
    }

    private static func parseVlessReality(
        id: String,
        name: String,
        city: String?,
        config: [String: Any]
    ) -> ServerProfile? {
        guard let vless = firstOutbound(config, type: "vless"),
              let (server, port) = dialFields(vless)
        else { return nil }
        let tls = vless["tls"] as? [String: Any]
        let reality = tls?["reality"] as? [String: Any]
        // optString-compatible: String or number (Android JSONObject.optString).
        guard let publicKey = optString(reality?["public_key"]),
              let shortId = optString(reality?["short_id"])
        else { return nil }
        let flow = optString(vless["flow"])
        let outboundCity = optString(vless["city"]) ?? city
        return ServerProfile(
            profile: .vlessReality(VlessRealityProfile(
                displayName: name,
                server: server,
                port: port,
                uuid: optString(vless["uuid"]) ?? "",
                tlsServerName: optString(tls?["server_name"]) ?? "www.cloudflare.com",
                publicKey: publicKey,
                shortId: shortId,
                flow: flow ?? "xtls-rprx-vision"
            )),
            id: id,
            city: outboundCity,
            bypassRuleSets: parseBypassRuleSets(config)
        )
    }

    private static func optString(_ raw: Any?) -> String? {
        if let s = raw as? String { return s.nilIfBlank }
        if let n = raw as? NSNumber { return n.stringValue.nilIfBlank }
        return nil
    }

    private static func firstOutbound(_ config: [String: Any], type: String) -> [String: Any]? {
        guard let outbounds = config["outbounds"] as? [[String: Any]] else { return nil }
        return outbounds.first { ($0["type"] as? String) == type }
    }

    private static func dialFields(_ outbound: [String: Any]) -> (String, Int)? {
        guard let server = (outbound["server"] as? String)?.nilIfBlank,
              let port = positivePort(outbound["server_port"])
        else { return nil }
        return (server, port)
    }

    private static func positivePort(_ raw: Any?) -> Int? {
        let value: Int?
        if let i = raw as? Int { value = i }
        else if let n = raw as? NSNumber { value = n.intValue }
        else { value = nil }
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Positive Mbps for Hysteria CC; 0 / negative / garbage → nil (BBR).
    private static func positiveMbps(_ raw: Any?) -> Int? {
        positivePort(raw)
    }

    /// Rule-set tags from API (`type: remote` binary). Apple uses tag only; URL ignored at runtime.
    /// Ignores TUN `route_exclude_address_set` (no-op under Apple NE platformInterface).
    static func parseBypassRuleSets(_ config: [String: Any]) -> [ApiBypassRuleSet] {
        guard let route = config["route"] as? [String: Any],
              let arr = route["rule_set"] as? [[String: Any]]
        else { return [] }
        var out: [String: ApiBypassRuleSet] = [:]
        var order: [String] = []
        for item in arr {
            let tag = (item["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !tag.isEmpty, !url.isEmpty else { continue }
            let type = ((item["type"] as? String) ?? "remote").trimmingCharacters(in: .whitespacesAndNewlines)
            let format = ((item["format"] as? String) ?? "binary").trimmingCharacters(in: .whitespacesAndNewlines)
            guard type == "remote", format == "binary" else { continue }
            if out[tag] == nil {
                order.append(tag)
                out[tag] = ApiBypassRuleSet(tag: tag)
            }
        }
        return order.compactMap { out[$0] }
    }
}
