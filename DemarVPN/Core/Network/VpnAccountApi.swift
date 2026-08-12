import Foundation

struct VpnAccount: Equatable, Sendable {
    var notifyNews: Bool
    var notifyImportant: Bool
    let vpnSubscription: String?
    let vpnExpiresAt: String?
}

struct VpnNotify: Equatable, Sendable {
    let notifyNews: Bool
    let notifyImportant: Bool
}

struct VpnTrafficServer: Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let bytes: Int64
}

struct VpnTraffic: Equatable, Sendable {
    let y: Int
    let m: Int
    let servers: [VpnTrafficServer]
    let total: Int64
    let limitBytes: Int64
}

enum VpnAccountApi {
    static func fetchAccount(userId: String, loginAt: String) async throws -> VpnAccount {
        parseAccount(try await post("vpn/account", sessionBody(userId, loginAt)))
    }

    static func updateNotify(
        userId: String,
        loginAt: String,
        notifyNews: Bool? = nil,
        notifyImportant: Bool? = nil
    ) async throws -> VpnNotify {
        var body = sessionBody(userId, loginAt)
        if let notifyNews { body["notifyNews"] = notifyNews }
        if let notifyImportant { body["notifyImportant"] = notifyImportant }
        let json = try await post("vpn/notify", body)
        return VpnNotify(
            notifyNews: (json["notifyNews"] as? Bool) ?? true,
            notifyImportant: (json["notifyImportant"] as? Bool) ?? true
        )
    }

    static func fetchTraffic(userId: String, loginAt: String) async throws -> VpnTraffic {
        parseTraffic(try await post("vpn/traffic", sessionBody(userId, loginAt)))
    }

    /// Pure helpers for unit tests — no network.
    static func parseAccount(_ json: [String: Any]) -> VpnAccount {
        VpnAccount(
            notifyNews: (json["notifyNews"] as? Bool) ?? true,
            notifyImportant: (json["notifyImportant"] as? Bool) ?? true,
            vpnSubscription: (json["vpnSubscription"] as? String)?.nilIfBlank,
            vpnExpiresAt: {
                guard let s = (json["vpnExpiresAt"] as? String)?.nilIfBlank, s != "null" else { return nil }
                return s
            }()
        )
    }

    static func parseTraffic(_ json: [String: Any]) -> VpnTraffic {
        let arr = json["servers"] as? [[String: Any]] ?? []
        let servers: [VpnTrafficServer] = arr.compactMap { item in
            guard let name = (item["name"] as? String)?.nilIfBlank else { return nil }
            return VpnTrafficServer(name: name, bytes: max(0, int64(item["bytes"])))
        }
        return VpnTraffic(
            y: (json["y"] as? Int) ?? (json["y"] as? NSNumber)?.intValue ?? 0,
            m: (json["m"] as? Int) ?? (json["m"] as? NSNumber)?.intValue ?? 0,
            servers: servers,
            total: max(0, int64(json["total"])),
            limitBytes: max(0, int64(json["limitBytes"]))
        )
    }

    /// Collapse to ≤6 slices: all if ≤6, else top-5 + Other.
    static func pieSlices(_ servers: [VpnTrafficServer], otherLabel: String) -> [VpnTrafficServer] {
        guard servers.count > 6 else { return servers }
        let top = Array(servers.prefix(5))
        let rest = servers.dropFirst(5).reduce(Int64(0)) { $0 + $1.bytes }
        return rest > 0 ? top + [VpnTrafficServer(name: otherLabel, bytes: rest)] : top
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let exp = min(4, max(1, Int(log(Double(bytes)) / log(1024.0))))
        let value = Double(bytes) / pow(1024.0, Double(exp))
        let unit = ["KB", "MB", "GB", "TB"][exp - 1]
        return value >= 100
            ? String(format: "%.0f %@", value, unit)
            : String(format: "%.1f %@", value, unit)
    }

    private static func sessionBody(_ userId: String, _ loginAt: String) -> [String: Any] {
        ["userId": userId, "loginAt": loginAt]
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await DemarHttp.postJSON(AuthApi.vpnAPIBaseURL.appendingPathComponent(path), body: body)
    }

    private static func int64(_ raw: Any?) -> Int64 {
        if let i = raw as? Int64 { return i }
        if let i = raw as? Int { return Int64(i) }
        if let n = raw as? NSNumber { return n.int64Value }
        return 0
    }
}
