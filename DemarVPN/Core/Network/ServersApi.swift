import Foundation

struct ServersListResult: Sendable {
    let vpnSubscription: String?
    let vpnExpiresAt: String?
    let servers: [ServerProfile]
}

enum ServersApi {
    static func fetchServers(userId: String, loginAt: String) async throws -> ServersListResult {
        let json = try await DemarHttp.postJSON(
            AuthApi.vpnAPIBaseURL.appendingPathComponent("vpn/servers"),
            body: ["userId": userId, "loginAt": loginAt]
        )
        let arr = json["servers"] as? [[String: Any]] ?? []
        var profiles: [ServerProfile] = []
        for item in arr {
            if let p = parseServerItem(item) {
                profiles.append(p)
            } else {
                let proto = item["protocol"] as? String ?? "?"
                let name = item["name"] as? String ?? "?"
                await MainActor.run {
                    AppLog.shared.append("[servers] skip unsupported protocol=\(proto) name=\(name)")
                }
            }
        }
        return ServersListResult(
            vpnSubscription: (json["vpnSubscription"] as? String)?.nilIfBlank,
            vpnExpiresAt: (json["vpnExpiresAt"] as? String)?.nilIfBlank,
            servers: profiles
        )
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
                obfsPassword: obfs
            ),
            id: id
        )
    }
}
