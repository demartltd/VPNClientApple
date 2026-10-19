import Foundation

/// Favorites + list filters (parity Android `ServersStore`).
enum ServersPreferencesStore {
    private enum Key {
        static let favorites = "demar_servers_favorites"
        static let tiers = "demar_servers_tiers"
        static let protocols = "demar_servers_protocols"
    }

    private static let defaults = UserDefaults.standard
    private static let allTiers = Set(ServerTier.allCases)
    private static let allProtocols = Set(ServerProtocol.allCases)

    static var favorites: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.favorites) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.favorites) }
    }

    static var tiers: Set<ServerTier> {
        get { readEnums(Key.tiers, fallback: allTiers) { ServerTier(rawValue: $0) } }
        set { writeEnums(Key.tiers, newValue.isEmpty ? allTiers : newValue) { $0.rawValue } }
    }

    static var protocols: Set<ServerProtocol> {
        get { readEnums(Key.protocols, fallback: allProtocols) { ServerProtocol(rawValue: $0) } }
        set { writeEnums(Key.protocols, newValue.isEmpty ? allProtocols : newValue) { $0.rawValue } }
    }

    @discardableResult
    static func toggleFavorite(_ id: String) -> Set<String> {
        var next = favorites
        if !next.insert(id).inserted { next.remove(id) }
        favorites = next
        return next
    }

    private static func readEnums<T>(
        _ key: String,
        fallback: Set<T>,
        parse: (String) -> T?
    ) -> Set<T> {
        guard let raw = defaults.stringArray(forKey: key) else { return fallback }
        let parsed = Set(raw.compactMap(parse))
        return parsed.isEmpty ? fallback : parsed
    }

    private static func writeEnums<T>(_ key: String, _ value: Set<T>, name: (T) -> String) {
        defaults.set(value.map(name).sorted(), forKey: key)
    }
}
