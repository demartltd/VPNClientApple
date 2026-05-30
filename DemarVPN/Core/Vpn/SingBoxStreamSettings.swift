import Foundation

enum SingBoxStreamSettings {
    static func tlsBlock(for profile: VlessProfile) -> [String: Any]? {
        switch profile.security {
        case "reality":
            return realityTls(query: profile.query)
        case "tls":
            return tls(query: profile.query)
        case "none", "":
            return nil
        default:
            return nil
        }
    }

    static func transportBlock(for profile: VlessProfile) -> [String: Any]? {
        let q = profile.query
        switch profile.network {
        case "tcp":
            return nil
        case "ws":
            var ws: [String: Any] = ["type": "ws"]
            if let path = decoded(q["path"]), !path.isEmpty { ws["path"] = path }
            if let host = cleaned(q["host"]), !host.isEmpty { ws["headers"] = ["Host": host] }
            if let earlyData = Int(cleaned(q["ed"]) ?? ""), earlyData > 0 {
                ws["max_early_data"] = earlyData
                ws["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            return ws
        case "grpc":
            var grpc: [String: Any] = ["type": "grpc"]
            if let path = decoded(q["path"])?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
               !path.isEmpty
            {
                grpc["service_name"] = path
            }
            return grpc
        case "httpupgrade":
            var h: [String: Any] = ["type": "httpupgrade"]
            if let host = cleaned(q["host"]), !host.isEmpty { h["host"] = host }
            if let path = decoded(q["path"]), !path.isEmpty { h["path"] = path }
            return h
        case "http":
            var http: [String: Any] = ["type": "http"]
            if let host = cleaned(q["host"]), !host.isEmpty { http["host"] = [host] }
            if let path = decoded(q["path"]), !path.isEmpty { http["path"] = path }
            return http
        case "quic":
            return ["type": "quic"]
        default:
            return nil
        }
    }

    private static func realityTls(query: [String: String]) -> [String: Any] {
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": VlessUriParser.sni(from: query),
            "reality": [
                "enabled": true,
                "public_key": cleaned(query["pbk"]) ?? "",
                "short_id": cleaned(query["sid"]) ?? "",
            ],
        ]
        if let fp = cleaned(query["fp"]), !fp.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fp]
        }
        return tls
    }

    private static func tls(query: [String: String]) -> [String: Any] {
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": VlessUriParser.sni(from: query),
            "insecure": boolFlag(query["allowinsecure"] ?? query["insecure"]),
        ]
        if let fp = cleaned(query["fp"]), !fp.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fp]
        }
        if let alpn = alpnList(query["alpn"]) { tls["alpn"] = alpn }
        return tls
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private static func decoded(_ value: String?) -> String? {
        guard let value else { return nil }
        let out = value.removingPercentEncoding ?? value
        return cleaned(out)
    }

    private static func boolFlag(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }

    private static func alpnList(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        let items = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }
}
