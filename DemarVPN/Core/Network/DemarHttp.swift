import Foundation
import Network
import Security
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
}

/// Control-plane HTTPS. Origin A for api/fastapi/account is DPI-broken on some ISPs;
/// dial Cloudflare anycast (same A as `demar.cc`) with SNI/Host left as the real hostname.
enum DemarHttp {
    static let clientID = "demar-vpn"

    private static let controlHosts: Set<String> = [
        "auth.example.invalid", "vpn.example.invalid", "account.example.invalid",
    ]
    private static let edgeBootstrap = "demar.cc"
    private static let edgeTtl: TimeInterval = 5 * 60
    private static let cfFallback = ["188.114.97.1", "188.114.96.1"]
    private static let attempts = 3
    private static let connectSeconds = 4
    private static let readSeconds = 8

    private static let edgeLock = NSLock()
    private static var edgeCache: (at: Date, ips: [IPv4Address])?

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

    static func isControlHost(_ host: String) -> Bool {
        controlHosts.contains(host.lowercased())
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
        guard let host = req.url?.host, isControlHost(host) else {
            return try await decodeViaURLSession(req)
        }
        let edges = edgeIPs()
        var last: Error?
        let tries = max(attempts, 1)
        for i in 0..<tries {
            let edge = edges[i % edges.count]
            do {
                return try await decodeViaEdge(req, sni: host, edge: edge)
            } catch let e as DemarAPIError {
                throw e
            } catch {
                last = error
                if i < tries - 1 {
                    let msg = "http: retry \(i + 1)/\(tries) edge=\(edge) — \(error.localizedDescription)"
                    Task { @MainActor in AppLog.shared.append(msg) }
                }
            }
        }
        throw last ?? URLError(.cannotConnectToHost)
    }

    private static func decodeViaURLSession(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        return try mapHTTP((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private static func decodeViaEdge(_ req: URLRequest, sni: String, edge: IPv4Address) async throws -> [String: Any] {
        let (code, data) = try await httpsOverEdge(req, sni: sni, edge: edge)
        return try mapHTTP(code, data)
    }

    private static func mapHTTP(_ code: Int, _ data: Data) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(code) else {
            throw DemarAPIError(
                message: (json["error"] as? String)?.nilIfBlank ?? "HTTP \(code)",
                statusCode: code,
                retryAfterSeconds: json["retryAfterSeconds"] as? Int,
                hint: (json["hint"] as? String)?.nilIfBlank
            )
        }
        return json
    }

    // MARK: - Edge dial (SNI = hostname, TCP = CF anycast)

    private static func httpsOverEdge(_ req: URLRequest, sni: String, edge: IPv4Address) async throws -> (Int, Data) {
        guard let url = req.url else { throw URLError(.badURL) }
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        let method = req.httpMethod ?? "GET"
        let body = req.httpBody ?? Data()

        var lines = ["\(method) \(path)\(query) HTTP/1.1", "Host: \(sni)", "Connection: close"]
        for (k, v) in req.allHTTPHeaderFields ?? [:] where k.lowercased() != "host" {
            lines.append("\(k): \(v)")
        }
        if method != "GET" || !body.isEmpty {
            lines.append("Content-Length: \(body.count)")
        }
        var wire = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        wire.append(body)

        let tls = NWProtocolTLS.Options()
        let opts = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(opts, sni)
        sec_protocol_options_set_verify_block(opts, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, sni as CFString))
            var err: CFError?
            complete(SecTrustEvaluateWithError(secTrust, &err))
        }, .global(qos: .utility))

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = connectSeconds
        let conn = NWConnection(host: .ipv4(edge), port: 443, using: NWParameters(tls: tls, tcp: tcp))

        return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            group.addTask {
                defer { conn.cancel() }
                try await waitReady(conn)
                try await sendAll(conn, wire)
                return try await readHTTP(conn)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(connectSeconds + readSeconds))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func waitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.go { cont.resume() }
                case .failed(let e): once.go { cont.resume(throwing: e) }
                case .cancelled: once.go { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private static func sendAll(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private static func readHTTP(_ conn: NWConnection) async throws -> (Int, Data) {
        var buf = Data()
        while true {
            let chunk = try await recv(conn)
            if chunk.isEmpty {
                if let parsed = parseHTTP(buf, allowClose: true) { return parsed }
                throw URLError(.badServerResponse)
            }
            buf.append(chunk)
            if let parsed = parseHTTP(buf, allowClose: false) { return parsed }
        }
    }

    private static func recv(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: data ?? (isComplete ? Data() : Data()))
            }
        }
    }

    private static func parseHTTP(_ data: Data, allowClose: Bool) -> (Int, Data)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<sep.lowerBound], encoding: .isoLatin1) else { return nil }
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let status = lines.first?.split(separator: " "), status.count >= 2, let code = Int(status[1]) else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            headers[k] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = sep.upperBound
        if let n = headers["content-length"].flatMap(Int.init) {
            guard data.count - bodyStart >= n else { return nil }
            return (code, data.subdata(in: bodyStart..<(bodyStart + n)))
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return decodeChunked(Data(data[bodyStart...])).map { (code, $0) }
        }
        return allowClose ? (code, Data(data[bodyStart...])) : nil
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var i = data.startIndex
        var out = Data()
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: crlf) else { return nil }
            let sizeHex = String(data: data[i..<lineEnd.lowerBound], encoding: .ascii)?
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeHex, radix: 16) else { return nil }
            i = lineEnd.upperBound
            if size == 0 { return out }
            guard data.distance(from: i, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(i, offsetBy: size)
            out.append(data[i..<end])
            i = data.index(end, offsetBy: 2)
        }
        return nil
    }

    private static func edgeIPs() -> [IPv4Address] {
        edgeLock.lock()
        defer { edgeLock.unlock() }
        if let c = edgeCache, Date().timeIntervalSince(c.at) < edgeTtl, !c.ips.isEmpty {
            return c.ips
        }
        var ips = resolveIPv4(edgeBootstrap)
        if ips.isEmpty {
            ips = cfFallback.compactMap { IPv4Address($0) }
        }
        edgeCache = (Date(), ips)
        return ips
    }

    private static func resolveIPv4(_ host: String) -> [IPv4Address] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [IPv4Address] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let ai = ptr {
            if ai.pointee.ai_family == AF_INET, let addr = ai.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(ai.pointee.ai_addrlen), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
                   let ip = IPv4Address(String(cString: buf)) {
                    out.append(ip)
                }
            }
            ptr = ai.pointee.ai_next
        }
        return out
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

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func go(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
