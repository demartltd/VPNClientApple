import Foundation

enum VlessUriParser {
    enum ParseMode: Sendable {
        case compatible
        case runtimeStrict
    }

    enum ParseError: LocalizedError {
        case unsupportedScheme(String)
        case missingUserId
        case missingHost
        case missingPort
        case unsupportedSecurity(String)
        case missingSni
        case missingFingerprint
        case missingPublicKey
        case missingShortId
        case invalidExtraJSON(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedScheme(scheme):
                "Unsupported scheme: \(scheme)"
            case .missingUserId:
                "Missing VLESS user id in URI userInfo."
            case .missingHost:
                "Missing VLESS server address in URI host."
            case .missingPort:
                "Missing or invalid VLESS server port."
            case let .unsupportedSecurity(security):
                "Unsupported security mode for runtime connect: \(security)."
            case .missingSni:
                "Missing SNI (query param `sni` or `host`)."
            case .missingFingerprint:
                "Missing TLS/REALITY fingerprint (query param `fp`)."
            case .missingPublicKey:
                "Missing REALITY public key (query param `pbk`)."
            case .missingShortId:
                "Missing REALITY short id (query param `sid`)."
            case let .invalidExtraJSON(detail):
                "Invalid xhttp `extra` JSON: \(detail)"
            }
        }
    }

    static func parse(_ uriString: String, mode: ParseMode = .compatible) throws -> VlessProfile {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vless://") else {
            throw ParseError.unsupportedScheme(URL(string: trimmed)?.scheme ?? "")
        }

        let body = String(trimmed.dropFirst("vless://".count))
        let (authorityPart, query, fragment) = splitQueryAndFragment(body)
        let (userId, host, port) = try parseAuthority(authorityPart)

        var normalizedQuery = query
        let network = VlessProfile.normalizeNetwork(query["type"] ?? query["network"] ?? "tcp")
        normalizedQuery["type"] = network

        let security = (query["security"] ?? "none").lowercased()
        let encryption = (query["encryption"] ?? "none").trimmingCharacters(in: .whitespacesAndNewlines)
        let flowRaw = (query["flow"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        try validate(security: security, query: query, mode: mode)
        try validateExtraIfPresent(query: query)

        return VlessProfile(
            displayName: displayName(fragment: fragment),
            serverAddress: host,
            serverPort: port,
            userId: userId,
            encryption: encryption.isEmpty ? "none" : encryption,
            flow: flowRaw.isEmpty ? nil : flowRaw,
            network: network,
            security: security,
            query: normalizedQuery
        )
    }

    private static func splitQueryAndFragment(_ body: String) -> (authority: String, query: [String: String], fragment: String) {
        var authority = body
        var fragment = ""
        if let hash = body.firstIndex(of: "#") {
            fragment = String(body[body.index(after: hash)...])
            authority = String(body[..<hash])
        }
        guard let qMark = authority.firstIndex(of: "?") else {
            return (authority, [:], fragment)
        }
        let queryPart = String(authority[authority.index(after: qMark)...])
        authority = String(authority[..<qMark])
        return (authority, parseQueryString(queryPart), fragment)
    }

    private static func parseQueryString(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        guard !raw.isEmpty else { return result }
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let keyPart = parts.first else { continue }
            let name = String(keyPart).lowercased()
            let encoded = parts.count > 1 ? String(parts[1]) : ""
            result[name] = encoded.removingPercentEncoding ?? encoded
        }
        return result
    }

    private static func parseAuthority(_ authority: String) throws -> (userId: String, host: String, port: Int) {
        guard let at = authority.lastIndex(of: "@") else { throw ParseError.missingUserId }
        let userRaw = String(authority[..<at])
        let userId = (userRaw.removingPercentEncoding ?? userRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else { throw ParseError.missingUserId }

        let hostPort = String(authority[authority.index(after: at)...])
        if hostPort.hasPrefix("[") {
            guard let end = hostPort.firstIndex(of: "]") else { throw ParseError.missingHost }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<end])
            let portPart = hostPort[hostPort.index(after: end)...].dropFirst() // ':'
            let port = Int(portPart) ?? 0
            guard port > 0 else { throw ParseError.missingPort }
            return (userId, host, port)
        }

        guard let colon = hostPort.lastIndex(of: ":") else { throw ParseError.missingPort }
        let host = String(hostPort[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(hostPort[hostPort.index(after: colon)...]) ?? 0
        guard !host.isEmpty else { throw ParseError.missingHost }
        guard port > 0 else { throw ParseError.missingPort }
        return (userId, host, port)
    }

    private static func validate(security: String, query: [String: String], mode: ParseMode) throws {
        if mode == .runtimeStrict {
            switch security {
            case "reality", "tls":
                break
            default:
                throw ParseError.unsupportedSecurity(security.isEmpty ? "<none>" : security)
            }
        }
        switch security {
        case "reality":
            guard !sni(from: query).isEmpty else { throw ParseError.missingSni }
            let fp = (query["fp"] ?? "chrome").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fp.isEmpty else { throw ParseError.missingFingerprint }
            guard !(query["pbk"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError.missingPublicKey
            }
            guard !(query["sid"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError.missingShortId
            }
        case "tls":
            guard !sni(from: query).isEmpty else { throw ParseError.missingSni }
        case "none", "":
            break
        default:
            break
        }
    }

    private static func validateExtraIfPresent(query: [String: String]) throws {
        guard let raw = query["extra"], !raw.isEmpty else { return }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        } catch {
            throw ParseError.invalidExtraJSON(raw.prefix(80).description)
        }
    }

    static func sni(from query: [String: String]) -> String {
        let sni = (query["sni"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sni.isEmpty { return sni }
        return (query["host"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func spiderX(from query: [String: String]) -> String? {
        guard let raw = query["spx"], !raw.isEmpty else { return nil }
        let decoded = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        return decoded.hasPrefix("/") ? decoded : "/\(decoded)"
    }

    private static func displayName(fragment: String) -> String {
        guard !fragment.isEmpty else { return "VLESS" }
        let decoded = fragment.removingPercentEncoding ?? fragment
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "VLESS" : trimmed
    }
}
