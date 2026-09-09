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

    static func isSiteGroupEnabled(_ settings: TunSettings, group: TunSiteGroup, isFree: Bool) -> Bool {
        if isFree { return true }
        return settings.siteGroupOverrides[group.id] ?? group.enabledByDefault
    }

    static func bypassHosts(
        settings: TunSettings,
        catalog: TunCatalog,
        isFree: Bool
    ) -> [String] {
        guard isRulesEnabled(settings, isFree: isFree) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for group in catalog.siteGroups where isSiteGroupEnabled(settings, group: group, isFree: isFree) {
            for site in group.sites {
                let host = site.host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { continue }
                let key = host.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(host)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func fingerprint(settings: TunSettings, catalog: TunCatalog, isFree: Bool) -> String {
        let hosts = bypassHosts(settings: settings, catalog: catalog, isFree: isFree)
        let groups = catalog.siteGroups
            .filter { isSiteGroupEnabled(settings, group: $0, isFree: isFree) }
            .map(\.id)
            .sorted()
        let on = isRulesEnabled(settings, isFree: isFree)
        return "h=\(hosts.joined(separator: ","));sg=\(groups.joined(separator: ","));r=\(on)"
    }
}
