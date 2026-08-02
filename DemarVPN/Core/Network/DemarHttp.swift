import Foundation
#if os(iOS)
import UIKit
#endif

struct DemarAPIError: Error, LocalizedError {
    let message: String
    let statusCode: Int
    let retryAfterSeconds: Int?
    let hint: String?

    var errorDescription: String? { message }
}

enum DemarHttp {
    static let clientID = "demar-vpn"

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    /// e.g. `iPhone (18.0) - DemarVPN (1.0.2) (iOS)` — ASCII, max 120.
    static var userAgent: String {
        let model = sanitize(deviceModel(), allowSpace: true, fallback: "Apple")
        let os = sanitize(osVersion(), allowSpace: false, fallback: "?")
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "\(model) (\(os)) - DemarVPN (\(ver)) (\(AppPlatform.label))".prefix(120).description
    }

    static func postJSON(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decodeJSON(req)
    }

    static func getJSON(_ url: URL, bearer: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyCommonHeaders(&req)
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await decodeJSON(req)
    }

    private static func applyCommonHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(clientID, forHTTPHeaderField: "X-Demar-Client")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    private static func decodeJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(code) else {
            let msg = (json["error"] as? String)?.nilIfBlank ?? "HTTP \(code)"
            let retry = json["retryAfterSeconds"] as? Int
            let hint = (json["hint"] as? String)?.nilIfBlank
            throw DemarAPIError(message: msg, statusCode: code, retryAfterSeconds: retry, hint: hint)
        }
        return json
    }

    private static func deviceModel() -> String {
        #if os(iOS)
        var uts = utsname()
        guard uname(&uts) == 0 else { return UIDevice.current.model }
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
        #else
        return "Apple"
        #endif
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    private static func sanitize(_ raw: String, allowSpace: Bool, fallback: String) -> String {
        let filtered = raw.filter {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || (allowSpace && $0 == " ")
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? fallback : filtered
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
