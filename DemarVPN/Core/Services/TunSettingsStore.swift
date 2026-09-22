import Foundation

enum TunSettingsStore {
    private enum Key {
        static let rulesEnabled = "tun_rules_enabled"
        static let adBlockEnabled = "tun_ad_block_enabled"
        static let siteOverrides = "tun_site_group_overrides"
        /// Legacy key — migrated once into SessionCacheStore / memory.
        static let legacyGroupsJson = "tun_groups_json"
    }

    private static let defaults = UserDefaults.standard
    private static let lock = NSLock()
    private static var ready = false
    private static var settings = TunSettings.empty
    private static var catalog = TunCatalog.empty

    static func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !ready else { return }
        settings = TunSettings(
            siteGroupOverrides: (defaults.dictionary(forKey: Key.siteOverrides) as? [String: Bool]) ?? [:],
            rulesEnabled: defaults.object(forKey: Key.rulesEnabled) as? Bool ?? true,
            adBlockEnabled: defaults.object(forKey: Key.adBlockEnabled) as? Bool
        )
        if let legacy = defaults.string(forKey: Key.legacyGroupsJson)?.nilIfBlank {
            catalog = TunGroupsApi.parse(legacy)
            defaults.removeObject(forKey: Key.legacyGroupsJson)
        }
        ready = true
    }

    static var currentSettings: TunSettings {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    static var currentCatalog: TunCatalog {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return catalog
    }

    static func cacheGroups(_ catalog: TunCatalog, raw: String? = nil, userId: String? = nil) {
        loadIfNeeded()
        lock.lock()
        self.catalog = catalog
        lock.unlock()
        if let raw, let userId {
            SessionCacheStore.saveTun(raw, userId: userId)
        }
    }

    static func hydrateFromCache(_ raw: String?) {
        loadIfNeeded()
        guard let raw, !raw.isEmpty else { return }
        lock.lock()
        catalog = TunGroupsApi.parse(raw)
        lock.unlock()
    }

    static func clearCatalog() {
        loadIfNeeded()
        lock.lock()
        catalog = .empty
        lock.unlock()
    }

    static func setRulesEnabled(_ enabled: Bool) {
        setFlag(\.rulesEnabled, enabled)
    }

    static func setAdBlockEnabled(_ enabled: Bool) {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard settings.adBlockEnabled != enabled else { return }
        settings.adBlockEnabled = enabled
        persistPrefsLocked()
    }

    static func setSiteGroupEnabled(_ groupId: String, enabled: Bool, defaultEnabled: Bool) {
        let id = groupId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        loadIfNeeded()
        lock.lock()
        if enabled == defaultEnabled {
            settings.siteGroupOverrides.removeValue(forKey: id)
        } else {
            settings.siteGroupOverrides[id] = enabled
        }
        persistPrefsLocked()
        lock.unlock()
    }

    /// Free plan always uses defaults; wipe paid-era overrides so they don't return after renew.
    static func resetToDefaults() {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard settings != .empty else { return }
        settings = .empty
        persistPrefsLocked()
    }

    static func effectiveBypassHosts(isFree: Bool) -> [String] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return TunEffective.bypassHosts(settings: settings, catalog: catalog, isFree: isFree)
    }

    static func effectiveAdBlockEnabled(isFree: Bool) -> Bool {
        TunEffective.isAdBlockEnabled(currentSettings, isFree: isFree)
    }

    static func fingerprint(isFree: Bool) -> String {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return TunEffective.fingerprint(settings: settings, catalog: catalog, isFree: isFree)
    }

    private static func setFlag(_ keyPath: WritableKeyPath<TunSettings, Bool>, _ enabled: Bool) {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard settings[keyPath: keyPath] != enabled else { return }
        settings[keyPath: keyPath] = enabled
        persistPrefsLocked()
    }

    private static func persistPrefsLocked() {
        defaults.set(settings.rulesEnabled, forKey: Key.rulesEnabled)
        if let adBlock = settings.adBlockEnabled {
            defaults.set(adBlock, forKey: Key.adBlockEnabled)
        } else {
            defaults.removeObject(forKey: Key.adBlockEnabled)
        }
        defaults.set(settings.siteGroupOverrides, forKey: Key.siteOverrides)
    }
}

/// Site-host A-records for NE excludes. Hot path = cache; refresh async.
enum BypassExcludeIPCache {
    private static let defaults = UserDefaults.standard
    private static let ttl: TimeInterval = 3600

    static func load(fingerprint: String) -> [String]? {
        let ips = defaults.stringArray(forKey: "bex|\(fingerprint)") ?? []
        let at = defaults.double(forKey: "bexAt|\(fingerprint)")
        guard !ips.isEmpty, at > 0, Date().timeIntervalSince1970 - at < ttl else { return nil }
        return ips
    }

    static func save(fingerprint: String, ips: [String]) {
        defaults.set(ips, forKey: "bex|\(fingerprint)")
        defaults.set(Date().timeIntervalSince1970, forKey: "bexAt|\(fingerprint)")
    }
}
