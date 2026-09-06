import Foundation
import NetworkExtension
#if canImport(Darwin)
import Darwin
#endif

/// GeoIP CIDR sidecars → NE `excludedRoutes`.
/// Libbox does not expand TUN `route_exclude_address_set` under `platformInterface`.
enum TunBypassCidrs {
    private static let lock = NSLock()
    private static var routeCache: [String: [NEIPv4Route]] = [:]

    static func ipv4Routes(forTags tags: [String], bundle: Bundle = .main) -> [NEIPv4Route] {
        let key = tags.filter { $0.hasPrefix("geoip") }.sorted().joined(separator: ",")
        guard !key.isEmpty else { return [] }
        lock.lock()
        if let cached = routeCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var routes: [NEIPv4Route] = []
        var keys = Set<String>()
        for tag in tags where tag.hasPrefix("geoip") {
            for cidr in loadCidrs(tag: tag, bundle: bundle) {
                guard let route = ipv4Route(cidr: cidr) else { continue }
                let routeKey = "\(route.destinationAddress)/\(route.destinationSubnetMask)"
                guard keys.insert(routeKey).inserted else { continue }
                routes.append(route)
            }
        }
        lock.lock()
        routeCache[key] = routes
        lock.unlock()
        return routes
    }

    static func loadCidrs(tag: String, bundle: Bundle = .main) -> [String] {
        let name = "\(tag).cidrs"
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "TunBypass")
        else { return [] }
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parses `a.b.c.d/prefix` into an IPv4 NE route.
    static func ipv4Route(cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32,
              isIPv4(parts[0])
        else { return nil }
        return NEIPv4Route(destinationAddress: parts[0], subnetMask: subnetMask(prefix: prefix))
    }

    private static func isIPv4(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private static func subnetMask(prefix: Int) -> String {
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return [
            (mask >> 24) & 0xff,
            (mask >> 16) & 0xff,
            (mask >> 8) & 0xff,
            mask & 0xff,
        ].map(String.init).joined(separator: ".")
    }
}
