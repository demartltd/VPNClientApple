import Foundation

struct TunSiteRef: Sendable, Hashable {
    let host: String
    let name: String
}

struct TunSiteGroup: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let sites: [TunSiteRef]
    let enabledByDefault: Bool
    /// Normal: outside TUN. OpenFlux (WL): through VPN — omit from bypass.
    let isWhiteList: Bool

    init(
        id: String,
        name: String,
        sites: [TunSiteRef],
        enabledByDefault: Bool = true,
        isWhiteList: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sites = sites
        self.enabledByDefault = enabledByDefault
        self.isWhiteList = isWhiteList
    }

    static func idFor(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct TunCatalog: Sendable {
    let siteGroups: [TunSiteGroup]
    static let empty = TunCatalog(siteGroups: [])
}

struct TunSettings: Sendable, Equatable {
    var siteGroupOverrides: [String: Bool]
    var rulesEnabled: Bool
    /// `nil` = plan default (free off, paid on); non-nil = user preference (paid only).
    var adBlockEnabled: Bool? = nil
    /// User custom apex hosts (Plus/VIP). Merged into effective bypass with site groups.
    var bypassHosts: [String] = []

    static let empty = TunSettings(siteGroupOverrides: [:], rulesEnabled: true)
}

enum TunEffective {
    static func isRulesEnabled(_ settings: TunSettings, isFree: Bool) -> Bool {
        isFree || settings.rulesEnabled
    }

    static func isAdBlockEnabled(_ settings: TunSettings, isFree: Bool) -> Bool {
        guard !isFree else { return false }
        return settings.adBlockEnabled ?? true
    }

    static func isSiteGroupEnabled(_ settings: TunSettings, group: TunSiteGroup) -> Bool {
        settings.siteGroupOverrides[group.id] ?? group.enabledByDefault
    }

    static func bypassHosts(
        settings: TunSettings,
        catalog: TunCatalog,
        isFree: Bool,
        whiteListVpnMode: Bool = false
    ) -> [String] {
        guard isRulesEnabled(settings, isFree: isFree) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        // Free: keep stored custom hosts in UI, but do not apply them.
        if !isFree {
            for host in settings.bypassHosts {
                guard seen.insert(host).inserted else { continue }
                out.append(host)
            }
        }
        for group in catalog.siteGroups where isSiteGroupEnabled(settings, group: group) {
            if whiteListVpnMode, group.isWhiteList { continue }
            for site in group.sites {
                guard let host = normalizeHost(site.host), seen.insert(host).inserted else { continue }
                out.append(host)
            }
        }
        return out.sorted()
    }

    /// Strip scheme/path/wildcards so `domain_suffix` matches cleanly.
    static func normalizeHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// URL or host → apex (`https://www.youtube.com/watch?` → `youtube.com`). Android `parseBypassHost`.
    static func parseBypassHost(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let withScheme = (t.contains("://") || t.hasPrefix("//")) ? t : "https://\(t)"
        guard var host = URL(string: withScheme)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        while host.hasPrefix(".") { host.removeFirst() }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, isBypassDomain(host) else { return nil }
        return host
    }

    /// Comma / whitespace separated entries → sorted unique apex hosts.
    static func parseBypassHosts(_ raw: String) -> [String] {
        let parts = raw.split { $0 == "," || $0.isWhitespace }.map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for part in parts {
            guard let host = parseBypassHost(part), seen.insert(host).inserted else { continue }
            out.append(host)
        }
        return out.sorted()
    }

    /// Label.Label… with ≥1 dot; rejects bare words and IPv4.
    private static let bypassDomainRegex = try! NSRegularExpression(
        pattern: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"#
    )
    private static let ipv4Regex = try! NSRegularExpression(
        pattern: #"^\d{1,3}(\.\d{1,3}){3}$"#
    )

    private static func isBypassDomain(_ host: String) -> Bool {
        let range = NSRange(host.startIndex..., in: host)
        guard bypassDomainRegex.firstMatch(in: host, range: range) != nil else { return false }
        return ipv4Regex.firstMatch(in: host, range: range) == nil
    }

    /// Names to A-lookup for NE exclude. Apex alone misses CDN IPs of www.*.
    static func excludeResolveHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for h in hosts {
            guard seen.insert(h).inserted else { continue }
            out.append(h)
            guard !h.hasPrefix("www.") else { continue }
            let www = "www.\(h)"
            if seen.insert(www).inserted { out.append(www) }
        }
        return out
    }

    static func fingerprint(
        settings: TunSettings,
        catalog: TunCatalog,
        isFree: Bool,
        whiteListVpnMode: Bool = false
    ) -> String {
        let hosts = bypassHosts(
            settings: settings,
            catalog: catalog,
            isFree: isFree,
            whiteListVpnMode: whiteListVpnMode
        )
        let groups = catalog.siteGroups
            .filter { isSiteGroupEnabled(settings, group: $0) }
            .map(\.id)
            .sorted()
        let on = isRulesEnabled(settings, isFree: isFree)
        return "h=\(hosts.joined(separator: ","));sg=\(groups.joined(separator: ","));r=\(on);wl=\(whiteListVpnMode)"
    }
}
