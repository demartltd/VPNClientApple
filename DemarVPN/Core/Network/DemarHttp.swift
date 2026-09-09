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
    var isSessionInvalid: Bool { statusCode == 401 }
    var isNotFound: Bool { statusCode == 404 }
    var isMediaTooLarge: Bool {
        statusCode == 413 || message.localizedCaseInsensitiveContains("too large")
    }
    var isChannelMismatch: Bool { message == "ticket_channel_mismatch" }
    var isNetworkUnreachable: Bool { statusCode == 0 }
}

enum DemarHttp {
    static let clientID = "demar-vpn"
    static let vpnBase = URL(string: "https://vpn.example.invalid")!

    private static let session: URLSession = makeSession(request: 15, resource: 25)
    private static let mediaSession: URLSession = makeSession(request: 180, resource: 180)

    /// e.g. `iPhone (18.0) - DemarVPN (1.0.2) (iOS)` — ASCII, max 120.
    static var userAgent: String {
        let model = sanitize(deviceModel(), allowSpace: true, fallback: "Apple")
        let os = sanitize(osVersion(), allowSpace: false, fallback: "?")
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "\(model) (\(os)) - DemarVPN (\(ver)) (\(AppPlatform.label))".prefix(120).description
    }

    static func vpnURL(_ path: String) -> URL {
        vpnBase.appendingPathComponent(path)
    }

    static func sessionBody(userId: String, loginAt: String) -> [String: Any] {
        ["userId": userId, "loginAt": loginAt]
    }

    static func vpnPost(_ path: String, _ body: [String: Any], media: Bool = false) async throws -> [String: Any] {
        try await postJSON(vpnURL(path), body: body, media: media)
    }

    static func vpnGet(_ path: String) async throws -> [String: Any] {
        try await getJSON(vpnURL(path))
    }

    /// Drop stale sockets after path / VPN / airplane changes.
    static func resetTransport() async {
        await session.reset()
        await mediaSession.reset()
    }

    static func postJSON(_ url: URL, body: [String: Any], media: Bool = false) async throws -> [String: Any] {
        // Build payload off the main actor — multi‑MB base64 freezes UI otherwise.
        let payload = try await Task.detached(priority: .userInitiated) {
            try JSONSerialization.data(withJSONObject: body)
        }.value
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = payload
        req.setValue("\(payload.count)", forHTTPHeaderField: "Content-Length")
        return try await decodeJSON(req, media: media)
    }

    static func patchJSON(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decodeJSON(req, media: false)
    }

    static func getJSON(_ url: URL, bearer: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyCommonHeaders(&req)
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await decodeJSON(req, media: false)
    }

    static func getData(_ url: URL, accept: String = "*/*", media: Bool = true) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(clientID, forHTTPHeaderField: "X-Demar-Client")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await perform(req, media: media)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DemarAPIError(
                message: msg?.nilIfBlank ?? "HTTP \(code)",
                statusCode: code,
                retryAfterSeconds: nil,
                hint: nil
            )
        }
        return data
    }

    static func applyCommonHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(clientID, forHTTPHeaderField: "X-Demar-Client")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    private static func makeSession(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = request
        cfg.timeoutIntervalForResource = resource
        return URLSession(configuration: cfg)
    }

    private static func decodeJSON(_ req: URLRequest, media: Bool) async throws -> [String: Any] {
        let (data, response) = try await perform(req, media: media)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(code) else {
            let msg = (json["error"] as? String)?.nilIfBlank ?? "HTTP \(code)"
            throw DemarAPIError(
                message: msg,
                statusCode: code,
                retryAfterSeconds: json["retryAfterSeconds"] as? Int,
                hint: (json["hint"] as? String)?.nilIfBlank
            )
        }
        return json
    }

    private static func perform(_ req: URLRequest, media: Bool) async throws -> (Data, URLResponse) {
        do {
            return try await dataOnce(req, media: media)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch let urlErr as URLError where isTransient(urlErr) {
            let kind = urlErr.code == .timedOut ? "timeout" : "network"
            await MainActor.run { AppLog.shared.append("[http] \(kind) — \(urlErr.code.rawValue), retry") }
            try? await Task.sleep(for: .milliseconds(400))
            do {
                return try await dataOnce(req, media: media)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw CancellationError()
            } catch {
                await resetTransport()
                await MainActor.run { AppLog.shared.append("[http] \(kind) after retry — transport reset") }
                throw networkError
            }
        } catch {
            await MainActor.run { AppLog.shared.append("[http] failed — \(type(of: error)): \(error.localizedDescription)") }
            throw networkError
        }
    }

    private static func dataOnce(_ req: URLRequest, media: Bool) async throws -> (Data, URLResponse) {
        try await (media ? mediaSession : session).data(for: req)
    }

    private static var networkError: DemarAPIError {
        DemarAPIError(
            message: String(localized: "Could not reach api. Try again"),
            statusCode: 0,
            retryAfterSeconds: nil,
            hint: nil
        )
    }

    private static func isTransient(_ err: URLError) -> Bool {
        switch err.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed, .secureConnectionFailed:
            true
        default:
            false
        }
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
