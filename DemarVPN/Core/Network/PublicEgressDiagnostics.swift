import Foundation
import Network
import Security

struct PublicEgressInfo: Sendable {
    let ip: String
    let country: String
}

enum ProbeKind: CaseIterable, Sendable {
    case tcp, https, tls
}

struct EgressHostProbe: Sendable {
    var tcpMs: Int = 0
    var httpsMs: Int = 0
    var tlsMs: Int = 0
}

enum PublicEgressDiagnostics {
    static let probeHosts = [
        "github.com", "bing.com", "ya.ru", "vk.ru", "x.com", "bbc.com", "www.gov.cn",
    ]
    static let probeTimeout: TimeInterval = 2.5
    private static let attempts = 3

    static let fallback = PublicEgressInfo(ip: "localhost", country: "None 🏳️")

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = probeTimeout
        cfg.timeoutIntervalForResource = probeTimeout
        return URLSession(configuration: cfg)
    }()

    static func egressHostProbeLabel(_ probe: EgressHostProbe) -> String {
        func ms(_ v: Int) -> String { v > 0 ? "\(v)" : "0" }
        return "TCP \(ms(probe.tcpMs)) · HTTPS \(ms(probe.httpsMs)) · TLS \(ms(probe.tlsMs))"
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
            var ordered = Array(repeating: EgressHostProbe(), count: hosts.count)
            for await (index, probe) in group {
                ordered[index] = probe
            }
            return ordered
        }
    }

    /// Selected kinds in parallel. Skipped kinds stay 0. (parity Android `InternetProbe.probeHost`)
    static func probeEgressHost(
        _ host: String,
        port: UInt16 = 443,
        kinds: Set<ProbeKind> = Set(ProbeKind.allCases)
    ) async -> EgressHostProbe {
        async let tcp = kinds.contains(.tcp) ? max(0, await probeTcpMs(host, port: port)) : 0
        async let https = kinds.contains(.https) ? max(0, await probeHttpsMs(host)) : 0
        async let tls = kinds.contains(.tls) ? max(0, await probeTlsMs(host, port: port)) : 0
        return EgressHostProbe(tcpMs: await tcp, httpsMs: await https, tlsMs: await tls)
    }

    // MARK: - Per-kind probes (best-of-3; -1 = fail)

    static func probeTcpMs(_ host: String, port: UInt16 = 443) async -> Int {
        await bestOf {
            await nwReadyMs(host: host, port: port, using: .tcp)
        }
    }

    static func probeHttpsMs(_ host: String) async -> Int {
        await bestOf {
            guard let url = URL(string: "https://\(host)/") else { return -1 }
            let started = Date()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = probeTimeout
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
                else { return -1 }
                return max(0, Int(Date().timeIntervalSince(started) * 1000))
            } catch {
                return -1
            }
        }
    }

    /// TLS handshake only (no HTTP). Trusts any cert — latency probe only.
    static func probeTlsMs(_ host: String, port: UInt16 = 443) async -> Int {
        await bestOf {
            await nwReadyMs(host: host, port: port, using: tlsTrustAllParams())
        }
    }

    /// QUIC Version Negotiation RTT (RFC 9000 §6). For HY2 uplink; Service Menu does not call this.
    static func probeQuicMs(_ host: String, port: UInt16 = 443) async -> Int {
        await bestOf {
            await quicOnceMs(host: host, port: port)
        }
    }

    // MARK: - Probe helpers

    private static func bestOf(_ attempt: () async -> Int) async -> Int {
        var best = -1
        for _ in 0..<attempts {
            let ms = await attempt()
            if ms >= 0, best < 0 || ms < best { best = ms }
        }
        return best
    }

    private static func tlsTrustAllParams() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in
            done(true)
        }, .global())
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private static func nwReadyMs(host: String, port: UInt16, using parameters: NWParameters) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return -1 }
        return await probeMs { finish in
            let started = Date()
            let conn = NWConnection(host: .init(host), port: nwPort, using: parameters)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.cancel()
                    finish(max(0, Int(Date().timeIntervalSince(started) * 1000)))
                case .failed, .cancelled:
                    finish(-1)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private static func quicOnceMs(host: String, port: UInt16) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return -1 }
        return await probeMs { finish in
            let started = Date()
            let conn = NWConnection(host: .init(host), port: nwPort, using: .udp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: quicGreaseInitial(), completion: .contentProcessed { error in
                        if error != nil {
                            conn.cancel()
                            finish(-1)
                            return
                        }
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 1500) { data, _, _, error in
                            conn.cancel()
                            if error != nil || data == nil {
                                finish(-1)
                            } else {
                                finish(max(0, Int(Date().timeIntervalSince(started) * 1000)))
                            }
                        }
                    })
                case .failed, .cancelled:
                    finish(-1)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    /// Long-header Initial, GREASE version `0x0a0a0a0a`, padded to 1200 bytes.
    private static func quicGreaseInitial() -> Data {
        var out = Data(count: 1200)
        out[0] = 0xc0
        out[1] = 0x0a; out[2] = 0x0a; out[3] = 0x0a; out[4] = 0x0a
        out[5] = 8
        for i in 6..<14 { out[i] = UInt8.random(in: 0...255) }
        out[14] = 8
        for i in 15..<23 { out[i] = UInt8.random(in: 0...255) }
        out[23] = 0x00
        return out
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
                finish(-1)
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
