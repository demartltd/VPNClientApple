import Foundation

enum SessionCacheStore {
    private enum Key {
        static let userId = "session_cache_user_id"
        static let servers = "session_cache_servers"
        static let account = "session_cache_account"
        static let traffic = "session_cache_traffic"
        static let tun = "session_cache_tun"
        static let reachability = "session_cache_reachability"
    }

    struct Snapshot: Sendable {
        let servers: [ServerProfile]
        let account: VpnAccount?
        let traffic: VpnTraffic?
        let tunRaw: String?
        let reachability: [String: ServerReachState]
    }

    static func load(userId: String) -> Snapshot? {
        let d = UserDefaults.standard
        guard d.string(forKey: Key.userId) == userId,
              let serversData = d.data(forKey: Key.servers),
              let serversJson = try? JSONSerialization.jsonObject(with: serversData) as? [String: Any]
        else { return nil }

        do {
            let serversResult = try ServersApi.parseServersResponse(serversJson)
            let account: VpnAccount? = d.data(forKey: Key.account).flatMap { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return VpnAccountApi.parseAccount(json)
            }
            let traffic: VpnTraffic? = d.data(forKey: Key.traffic).flatMap { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return VpnAccountApi.parseTraffic(json)
            }
            let tunRaw = d.string(forKey: Key.tun)?.nilIfBlank
            let reachability = d.string(forKey: Key.reachability)
                .map(ServerReachState.decodeCache) ?? [:]
            return Snapshot(
                servers: serversResult.servers,
                account: account,
                traffic: traffic,
                tunRaw: tunRaw,
                reachability: reachability
            )
        } catch {
            return nil
        }
    }

    static func saveServers(_ json: [String: Any], userId: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let d = UserDefaults.standard
        d.set(userId, forKey: Key.userId)
        d.set(data, forKey: Key.servers)
    }

    static func saveTun(_ raw: String, userId: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let d = UserDefaults.standard
        d.set(userId, forKey: Key.userId)
        d.set(trimmed, forKey: Key.tun)
    }

    static func saveAccount(_ account: VpnAccount, userId: String) {
        let json: [String: Any] = [
            "notifyNews": account.notifyNews,
            "notifyImportant": account.notifyImportant,
            "vpnSubscription": account.vpnSubscription as Any,
            "vpnExpiresAt": account.vpnExpiresAt as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let d = UserDefaults.standard
        d.set(userId, forKey: Key.userId)
        d.set(data, forKey: Key.account)
    }

    static func saveTraffic(_ traffic: VpnTraffic, userId: String) {
        let json: [String: Any] = [
            "y": traffic.y,
            "m": traffic.m,
            "total": traffic.total,
            "limitBytes": traffic.limitBytes,
            "servers": traffic.servers.map { ["name": $0.name, "bytes": $0.bytes] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let d = UserDefaults.standard
        d.set(userId, forKey: Key.userId)
        d.set(data, forKey: Key.traffic)
    }

    static func saveReachability(_ map: [String: ServerReachState], userId: String) {
        let d = UserDefaults.standard
        d.set(userId, forKey: Key.userId)
        d.set(ServerReachState.encodeCache(map), forKey: Key.reachability)
    }

    static func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Key.userId)
        d.removeObject(forKey: Key.servers)
        d.removeObject(forKey: Key.account)
        d.removeObject(forKey: Key.traffic)
        d.removeObject(forKey: Key.tun)
        d.removeObject(forKey: Key.reachability)
    }
}
