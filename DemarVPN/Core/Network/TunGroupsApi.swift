import Foundation

enum TunGroupsApi {
    private static let maxBytes = 2 * 1024 * 1024

    struct Payload: Sendable {
        let raw: String
        let catalog: TunCatalog
    }

    static func fetch() async -> Payload? {
        do {
            return try await KeyedFlight.run("tun.groups") {
                let data = try await DemarHttp.getData(DemarHttp.vpnURL("tun"), media: false)
                guard data.count <= maxBytes else {
                    await MainActor.run { AppLog.shared.append("[tun] groups response too large") }
                    return nil as Payload?
                }
                guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
                    await MainActor.run { AppLog.shared.append("[tun] groups empty") }
                    return nil
                }
                return Payload(raw: raw, catalog: parse(raw))
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { AppLog.shared.append("[tun] groups fetch failed — \(message)") }
            return nil
        }
    }

    static func parse(_ raw: String) -> TunCatalog {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }
        return TunCatalog(siteGroups: parseSiteGroups(root["sites"]))
    }

    private static func parseSiteGroups(_ node: Any?) -> [TunSiteGroup] {
        guard let arr = node as? [[String: Any]] else { return [] }
        var list: [TunSiteGroup] = []
        for item in arr {
            guard let name = (item["name"] as? String)?.nilIfBlank else { continue }
            list.append(TunSiteGroup(
                id: TunSiteGroup.idFor(name),
                name: name,
                sites: parseSites(item["sites"]),
                enabledByDefault: item["enabledByDefault"] as? Bool ?? true
            ))
        }
        return list
    }

    private static func parseSites(_ node: Any?) -> [TunSiteRef] {
        guard let arr = node as? [[String: Any]] else { return [] }
        var list: [TunSiteRef] = []
        for item in arr {
            guard let host = (item["host"] as? String)?.nilIfBlank else { continue }
            let name = (item["name"] as? String)?.nilIfBlank ?? host
            list.append(TunSiteRef(host: host, name: name))
        }
        return list
    }
}
