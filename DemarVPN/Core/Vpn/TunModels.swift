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

    static func idFor(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct TunCatalog: Sendable {
    let siteGroups: [TunSiteGroup]
    static let empty = TunCatalog(siteGroups: [])
}

struct TunSettings: Sendable {
    var siteGroupOverrides: [String: Bool]
    var rulesEnabled: Bool

    static let empty = TunSettings(siteGroupOverrides: [:], rulesEnabled: true)
}

enum TunEffective {
    static func isRulesEnabled(_ settings: TunSettings, isFree: Bool) -> Bool {
        isFree || settings.rulesEnabled
    }

    static func isSiteGroupEnabled(_ settings: TunSettings, group: TunSiteGroup) -> Bool {
        settings.siteGroupOverrides[group.id] ?? group.enabledByDefault
    }

    static func bypassHosts(
        settings: TunSettings,
        catalog: TunCatalog,
        isFree: Bool
    ) -> [String] {
        guard isRulesEnabled(settings, isFree: isFree) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for group in catalog.siteGroups where isSiteGroupEnabled(settings, group: group) {
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

    static func fingerprint(settings: TunSettings, catalog: TunCatalog, isFree: Bool) -> String {
        let hosts = bypassHosts(settings: settings, catalog: catalog, isFree: isFree)
        let groups = catalog.siteGroups
            .filter { isSiteGroupEnabled(settings, group: $0) }
            .map(\.id)
            .sorted()
        let on = isRulesEnabled(settings, isFree: isFree)
        return "h=\(hosts.joined(separator: ","));sg=\(groups.joined(separator: ","));r=\(on)"
    }
}
