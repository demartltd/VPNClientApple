import Foundation
import Network

struct PublicEgressInfo: Sendable {
    let ip: String
    let country: String
}

struct EgressHostProbe: Sendable {
    let tcpMs: Int
    let httpsMs: Int
}

enum PublicEgressDiagnostics {
    static let probeHosts = [
        "github.com", "bing.com", "ya.ru", "vk.ru", "x.com", "bbc.com", "www.gov.cn",
    ]
    static let probeTimeout: TimeInterval = 2.5

    static let fallback = PublicEgressInfo(ip: "localhost", country: "None 🏳️")

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = probeTimeout
        cfg.timeoutIntervalForResource = probeTimeout
        return URLSession(configuration: cfg)
    }()

    static func egressHostProbeLabel(_ probe: EgressHostProbe) -> String {
        let t = probe.tcpMs > 0 ? "\(probe.tcpMs)" : "0"
        let h = probe.httpsMs > 0 ? "\(probe.httpsMs)" : "0"
        return "TCP \(t) · HTTPS \(h)"
    }

    /// `example.com`, `https://host/path`, `203.0.113.1` → hostname for probes.
    static func normalizeProbeHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let host = URL(string: withScheme)?.host, !host.isEmpty { return host }
        let bare = trimmed.split { "/:".contains($0) }.first.map(String.init) ?? ""
        return bare.isEmpty ? nil : bare
    }

    static func censorPublicIPv4ForDisplay(_ ip: String) -> String {
        if ip == "localhost" || ip == "127.0.0.1" { return "localhost" }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return "**.***" }
        return "**.***.\(parts[2]).\(parts[3])"
    }

    static func fetchPublicEgressGeo() async -> PublicEgressInfo {
        // One provider at a time; next only after failure (parity Windows).
        let providers: [() async -> PublicEgressInfo?] = [
            { await fetchCloudflareTrace() },
            { await fetchIpWhoIs(url: "https://ipwho.is/") },
            { await fetchIpApiCo() },
            { await fetchPublicIPv4Info() },
        ]
        for provider in providers {
            if let info = await provider(), isIPv4(info.ip) { return info }
        }
        return fallback
    }

    static func probeAllHosts(
        onHostReady: (@Sendable (Int, EgressHostProbe) -> Void)? = nil
    ) async -> [EgressHostProbe] {
        await probeHosts(probeHosts, onHostReady: onHostReady)
    }

    static func probeHosts(
        _ hosts: [String],
        onHostReady: (@Sendable (Int, EgressHostProbe) -> Void)? = nil
    ) async -> [EgressHostProbe] {
        guard !hosts.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, EgressHostProbe).self, returning: [EgressHostProbe].self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    let probe = await probeEgressHost(host)
                    onHostReady?(index, probe)
                    return (index, probe)
                }
            }
            var ordered = Array(repeating: EgressHostProbe(tcpMs: 0, httpsMs: 0), count: hosts.count)
            for await (index, probe) in group {
                ordered[index] = probe
            }
            return ordered
        }
    }

    static func probeEgressHost(_ host: String) async -> EgressHostProbe {
        let zero = EgressHostProbe(tcpMs: 0, httpsMs: 0)
        return await withTaskGroup(of: EgressHostProbe.self) { group in
            group.addTask {
                async let tcp = tcp443Ms(host)
                async let https = httpsSiteMs(host)
                return EgressHostProbe(tcpMs: await tcp, httpsMs: await https)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(probeTimeout))
                return zero
            }
            let result = await group.next() ?? zero
            group.cancelAll()
            return result
        }
    }

    // MARK: - Probes

    private static func tcp443Ms(_ host: String) async -> Int {
        await probeMs { finish in
            let started = Date()
            let conn = NWConnection(host: .init(host), port: 443, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.cancel()
                    finish(max(0, Int(Date().timeIntervalSince(started) * 1000)))
                case .failed, .cancelled:
                    finish(0)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private static func httpsSiteMs(_ host: String) async -> Int {
        guard let url = URL(string: "https://\(host)/") else { return 0 }
        let started = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = probeTimeout
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode >= 100 else { return 0 }
            return max(0, Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return 0
        }
    }

    private static func probeMs(
        _ start: @escaping @Sendable (@escaping @Sendable (Int) -> Void) -> Void
    ) async -> Int {
        await withCheckedContinuation { cont in
            let gate = OnceGate()
            let finish: @Sendable (Int) -> Void = { ms in
                guard gate.take() else { return }
                cont.resume(returning: ms)
            }
            start(finish)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + probeTimeout) {
                finish(0)
            }
        }
    }

    // MARK: - Geo

    private static func fetchPublicIPv4Info() async -> PublicEgressInfo? {
        if let ip = await firstIPv4(from: [
            "https://api.ipify.org?format=json",
            "https://api64.ipify.org?format=json",
            "https://ipv4.icanhazip.com/",
            "https://ifconfig.me/ip",
            "https://api.ip.sb/ip",
        ]) {
            if let byIp = await fetchIpWhoIs(url: "https://ipwho.is/\(ip)") { return byIp }
            return PublicEgressInfo(ip: ip, country: fallback.country)
        }
        return nil
    }

    private static func firstIPv4(from urls: [String]) async -> String? {
        for url in urls {
            if url.contains("format=json") {
                guard let body = await httpGetBody(url: url),
                      let data = body.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ip = (obj["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      isIPv4(ip)
                else { continue }
                return ip
            }
            guard let body = await httpGetBody(url: url)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                isIPv4(body)
            else { continue }
            return body
        }
        return nil
    }

    private static func fetchIpWhoIs(url: String) async -> PublicEgressInfo? {
        guard let body = await httpGetBody(url: url),
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = obj["success"] as? Bool, success,
              let ip = (obj["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isIPv4(ip),
              let country = (obj["country"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !country.isEmpty
        else { return nil }
        let code = (obj["country_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PublicEgressInfo(ip: ip, country: countryWithFlag(country, code: code))
    }

    private static func fetchIpApiCo() async -> PublicEgressInfo? {
        guard let body = await httpGetBody(url: "https://ipapi.co/json/"),
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = (obj["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isIPv4(ip),
              let country = (obj["country_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !country.isEmpty
        else { return nil }
        let code = (obj["country_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PublicEgressInfo(ip: ip, country: countryWithFlag(country, code: code))
    }

    private static func fetchCloudflareTrace() async -> PublicEgressInfo? {
        guard let body = await httpGetBody(url: "https://www.cloudflare.com/cdn-cgi/trace") else {
            return nil
        }
        var ip: String?
        var loc: String?
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "ip", isIPv4(value) { ip = value }
            if key == "loc", value.count == 2 { loc = value.uppercased() }
        }
        guard let ip else { return nil }
        if let loc {
            return PublicEgressInfo(ip: ip, country: countryWithFlag(loc, code: loc))
        }
        return PublicEgressInfo(ip: ip, country: fallback.country)
    }

    private static func httpGetBody(url: String) async -> String? {
        await withTimeout(seconds: probeTimeout) { () -> String? in
            guard let endpoint = URL(string: url) else { return nil }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = probeTimeout
            request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8)
                else { return nil }
                return text
            } catch {
                return nil
            }
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part), (0...255).contains(n) else { return false }
        }
        return true
    }

    private static func countryWithFlag(_ country: String, code: String) -> String {
        let flag = flagEmoji(from: code)
        return flag.isEmpty ? country : "\(country) \(flag)"
    }

    private static func flagEmoji(from countryCode: String) -> String {
        let upper = countryCode.uppercased()
        guard upper.count == 2 else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in upper.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90,
                  let regional = UnicodeScalar(127397 + scalar.value)
            else { return "" }
            scalars.append(regional)
        }
        return String(scalars)
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
