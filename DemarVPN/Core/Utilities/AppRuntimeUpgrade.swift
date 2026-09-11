import Foundation

/// Detects app/core bump and wipes stale VPN runtime left in the App Group across updates.
enum AppRuntimeUpgrade {
    private static let tokenKey = "demar_runtime_upgrade_token"

    static var currentToken: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(build)|\(BundledCoreVersion.label)"
    }

    /// Returns `true` once per build/core bump (not on first install). Runs `onUpgrade` when bumped.
    @discardableResult
    static func consumeIfUpgraded(
        defaults: UserDefaults = .standard,
        token: String = currentToken,
        onUpgrade: () -> Void = { wipeStaleRuntime() }
    ) -> Bool {
        let previous = defaults.string(forKey: tokenKey)
        guard previous != token else { return false }
        defaults.set(token, forKey: tokenKey)
        guard previous != nil else { return false }
        onUpgrade()
        return true
    }

    static func wipeStaleRuntime() {
        VpnSharedStore.clearConnectArtifacts()
        guard let assetDir = try? VpnAppGroup.assetDirectoryURL() else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: assetDir.appendingPathComponent("bundled_version.txt"))
        guard let names = try? fm.contentsOfDirectory(atPath: assetDir.path) else { return }
        for name in names where name == "cache.db" || name.hasPrefix("cache.db") {
            try? fm.removeItem(at: assetDir.appendingPathComponent(name))
        }
    }
}
