import Foundation

enum TunSettingsStore {
    private enum Key {
        static let rulesEnabled = "tun_rules_enabled"
        static let adBlockEnabled = "tun_ad_block_enabled"
        static let siteOverrides = "tun_site_group_overrides"
        static let bypassHosts = "tun_bypass_hosts"
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
        let hosts = (defaults.stringArray(forKey: Key.bypassHosts) ?? [])
            .compactMap(TunEffective.parseBypassHost)
        settings = TunSettings(
            siteGroupOverrides: (defaults.dictionary(forKey: Key.siteOverrides) as? [String: Bool]) ?? [:],
            rulesEnabled: defaults.object(forKey: Key.rulesEnabled) as? Bool ?? true,
            adBlockEnabled: defaults.object(forKey: Key.adBlockEnabled) as? Bool,
            bypassHosts: Array(Set(hosts)).sorted()
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

    @discardableResult
    static func addBypassHosts(_ raw: String) -> [String] {
        let parsed = TunEffective.parseBypassHosts(raw)
        guard !parsed.isEmpty else { return [] }
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        var seen = Set(settings.bypassHosts)
        var added: [String] = []
        for host in parsed where seen.insert(host).inserted {
            added.append(host)
        }
        guard !added.isEmpty else { return [] }
        settings.bypassHosts = (settings.bypassHosts + added).sorted()
        persistPrefsLocked()
        return added
    }

    static func removeBypassHost(_ host: String) {
        let h = TunEffective.parseBypassHost(host) ?? host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return }
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        let next = settings.bypassHosts.filter { $0 != h }
        guard next.count != settings.bypassHosts.count else { return }
        settings.bypassHosts = next
        persistPrefsLocked()
    }

    /// Free / defaults: wipe overrides + ad block; keep custom hosts (shown but not applied on Free).
    /// Pass `clearBypassHosts: true` on sign-out.
    static func resetToDefaults(clearBypassHosts: Bool = false) {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        let hosts = clearBypassHosts ? [] : settings.bypassHosts
        let next = TunSettings(
            siteGroupOverrides: [:],
            rulesEnabled: true,
            bypassHosts: hosts
        )
        guard settings != next else { return }
        settings = next
        persistPrefsLocked()
    }

    static func effectiveBypassHosts(isFree: Bool, whiteListVpnMode: Bool = false) -> [String] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return TunEffective.bypassHosts(
            settings: settings,
            catalog: catalog,
            isFree: isFree,
            whiteListVpnMode: whiteListVpnMode
        )
    }

    static func effectiveAdBlockEnabled(isFree: Bool) -> Bool {
        TunEffective.isAdBlockEnabled(currentSettings, isFree: isFree)
    }

    static func fingerprint(isFree: Bool, whiteListVpnMode: Bool = false) -> String {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return TunEffective.fingerprint(
            settings: settings,
            catalog: catalog,
            isFree: isFree,
            whiteListVpnMode: whiteListVpnMode
        )
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
        defaults.set(settings.bypassHosts, forKey: Key.bypassHosts)
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
