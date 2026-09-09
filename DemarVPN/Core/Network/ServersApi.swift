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
        let protocolName = ((item["protocol"] as? String) ?? "").lowercased()
        guard protocolName == "hysteria2" || protocolName.isEmpty else { return nil }

        if let configRaw = (item["clientConfigJson"] as? String)?.nilIfBlank,
           let configData = configRaw.data(using: .utf8),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let profile = parseHysteria2(id: id, name: name, city: city, config: config)
        {
            return profile
        }

        // Preview / guest list: metadata only, no credentials — show in UI, block connect.
        return ServerProfile(
            hysteria2: Hysteria2Profile(
                displayName: name,
                city: city,
                server: "preview",
                port: 443,
                password: "",
                tlsServerName: "preview"
            ),
            id: id
        )
    }

    private static func parseHysteria2(
        id: String,
        name: String,
        city: String?,
        config: [String: Any]
    ) -> ServerProfile? {
        guard let outbounds = config["outbounds"] as? [[String: Any]],
              let hy2 = outbounds.first(where: { ($0["type"] as? String) == "hysteria2" })
        else { return nil }
        guard let server = (hy2["server"] as? String)?.nilIfBlank else { return nil }
        let password = (hy2["password"] as? String) ?? ""
        let port: Int = {
            if let i = hy2["server_port"] as? Int { return i }
            if let n = hy2["server_port"] as? NSNumber { return n.intValue }
            return 0
        }()
        guard port > 0 else { return nil }
        let tls = hy2["tls"] as? [String: Any]
        let tlsName = (tls?["server_name"] as? String)?.nilIfBlank ?? server
        let alpn: [String] = {
            guard let arr = tls?["alpn"] as? [String], !arr.isEmpty else { return ["h3"] }
            return arr.filter { !$0.isEmpty }
        }()
        let obfs = ((hy2["obfs"] as? [String: Any])?["password"] as? String)?.nilIfBlank
        let outboundCity = (hy2["city"] as? String)?.nilIfBlank ?? city
        return ServerProfile(
            hysteria2: Hysteria2Profile(
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
            ),
            id: id,
            bypassRuleSets: parseBypassRuleSets(config)
        )
    }

    /// Positive Mbps for Hysteria CC; 0 / negative / garbage → nil (BBR).
    private static func positiveMbps(_ raw: Any?) -> Int? {
        let value: Int?
        if let i = raw as? Int { value = i }
        else if let n = raw as? NSNumber { value = n.intValue }
        else { value = nil }
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Remote rule-sets from API; ignores TUN `route_exclude_address_set` (no-op under Apple NE platformInterface).
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
                out[tag] = ApiBypassRuleSet(tag: tag, url: url)
            }
        }
        return order.compactMap { out[$0] }
    }
}
