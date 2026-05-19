import Foundation

enum VlessUriParser {
    enum ParseError: LocalizedError {
        case unsupportedScheme(String)
        case missingUserId
        case missingHost
        case missingPort
        case unsupportedSecurity(String)
        case missingTransport
        case missingSni
        case missingFingerprint
        case missingPublicKey
        case missingShortId

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
                "Only VLESS+REALITY is supported for now (security=\(security))."
            case .missingTransport:
                "Missing transport type (query param `type`)."
            case .missingSni:
                "Missing REALITY SNI (query param `sni`)."
            case .missingFingerprint:
                "Missing REALITY fingerprint (query param `fp`)."
            case .missingPublicKey:
                "Missing REALITY public key (query param `pbk`)."
            case .missingShortId:
                "Missing REALITY short id (query param `sid`)."
            }
        }
    }

    static func parse(_ uriString: String) throws -> VlessRealityProfile {
        guard let components = URLComponents(string: uriString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ParseError.missingHost
        }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "vless" else {
            throw ParseError.unsupportedScheme(components.scheme ?? "")
        }

        let userId = (components.user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else { throw ParseError.missingUserId }

        let host = (components.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ParseError.missingHost }

        let port = components.port ?? 0
        guard port > 0 else { throw ParseError.missingPort }

        let query = lowercasedQuery(components)

        let security = (query["security"] ?? "").lowercased()
        guard security == "reality" else {
            throw ParseError.unsupportedSecurity(security.isEmpty ? "<none>" : security)
        }

        let transport = (query["type"] ?? "").lowercased()
        guard !transport.isEmpty else { throw ParseError.missingTransport }

        let sni = (query["sni"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sni.isEmpty else { throw ParseError.missingSni }

        let fingerprint = (query["fp"] ?? "chrome").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { throw ParseError.missingFingerprint }

        let publicKey = (query["pbk"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty else { throw ParseError.missingPublicKey }

        let shortId = (query["sid"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortId.isEmpty else { throw ParseError.missingShortId }

        let flowRaw = (query["flow"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return VlessRealityProfile(
            displayName: displayName(from: components),
            serverAddress: host,
            serverPort: port,
            userId: userId,
            transport: transport,
            sni: sni,
            fingerprint: fingerprint,
            publicKey: publicKey,
            shortId: shortId,
            flow: flowRaw.isEmpty ? nil : flowRaw
        )
    }

    private static func lowercasedQuery(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            result[item.name.lowercased()] = value
        }
        return result
    }

    private static func displayName(from components: URLComponents) -> String {
        let raw = components.fragment ?? ""
        guard !raw.isEmpty else { return "VLESS" }
        let decoded = raw.removingPercentEncoding ?? raw
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "VLESS" : trimmed
    }
}
