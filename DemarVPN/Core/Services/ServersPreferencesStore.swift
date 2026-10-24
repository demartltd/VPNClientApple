import Foundation

/// Favorites + server list filters.
/// Stores only **off** badges; missing / unknown → ON (§10).
enum ServersPreferencesStore {
    private enum Key {
        static let favorites = "demar_servers_favorites"
        /// Fresh keys — old enabled/disabled/schema prefs ignored.
        static let offTiers = "demar_servers_off_tiers"
        static let offProtocols = "demar_servers_off_protocols"
    }

    private static let defaults = UserDefaults.standard

    static var favorites: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.favorites) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.favorites) }
    }

    static var tiers: Set<ServerTier> {
        get { on(offKey: Key.offTiers, parse: ServerTier.init(rawValue:)) }
        set { setOff(newValue, offKey: Key.offTiers, name: \.rawValue) }
    }

    static var protocols: Set<ServerProtocol> {
        get { on(offKey: Key.offProtocols, parse: ServerProtocol.init(rawValue:)) }
        set { setOff(newValue, offKey: Key.offProtocols, name: \.rawValue) }
    }

    @discardableResult
    static func toggleFavorite(_ id: String) -> Set<String> {
        var next = favorites
        if !next.insert(id).inserted { next.remove(id) }
        favorites = next
        return next
    }

    private static func on<T: CaseIterable & Hashable>(
        offKey: String,
        parse: (String) -> T?
    ) -> Set<T> where T.AllCases: Sequence, T.AllCases.Element == T {
        Set(T.allCases).subtracting((defaults.stringArray(forKey: offKey) ?? []).compactMap(parse))
    }

    private static func setOff<T: CaseIterable & Hashable>(
        _ enabled: Set<T>,
        offKey: String,
        name: (T) -> String
    ) where T.AllCases: Sequence, T.AllCases.Element == T {
        let all = Set(T.allCases)
        let on = enabled.isEmpty ? all : enabled
        defaults.set(all.subtracting(on).map(name).sorted(), forKey: offKey)
    }
}
