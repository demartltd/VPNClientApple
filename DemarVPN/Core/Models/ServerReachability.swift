import Foundation

enum ServerReachStatus: String, Sendable {
    case checking
    case online
    case offline
}

struct ServerReachState: Equatable, Sendable {
    var status: ServerReachStatus
    /// TCP RTT ms.
    var latencyMs: Int?
    /// TLS / QUIC handshake RTT ms (list metric).
    var tlsMs: Int?

    static let checking = ServerReachState(status: .checking)
    static let offline = ServerReachState(status: .offline)

    static func formatMs(_ ms: Int?) -> String {
        ms.map { "~\($0)ms" } ?? "n/a"
    }

    static func fromProbes(tcpMs: Int, tlsMs: Int) -> ServerReachState {
        let tcpOk = tcpMs >= 0
        let tlsOk = tlsMs >= 0
        if !tcpOk && !tlsOk { return .offline }
        return ServerReachState(
            status: .online,
            latencyMs: tcpOk ? tcpMs : nil,
            tlsMs: tlsOk ? tlsMs : nil
        )
    }

    func toCacheJSON() -> [String: Any]? {
        if status == .checking, latencyMs == nil, tlsMs == nil { return nil }
        var obj: [String: Any] = [
            "status": status == .offline ? ServerReachStatus.offline.rawValue : ServerReachStatus.online.rawValue,
        ]
        if let latencyMs { obj["latencyMs"] = latencyMs }
        if let tlsMs { obj["tlsMs"] = tlsMs }
        return obj
    }

    static func fromCacheJSON(_ obj: [String: Any]) -> ServerReachState? {
        let status: ServerReachStatus
        switch obj["status"] as? String {
        case ServerReachStatus.offline.rawValue: status = .offline
        case ServerReachStatus.online.rawValue: status = .online
        default: return nil
        }
        return ServerReachState(
            status: status,
            latencyMs: intMs(obj, "latencyMs"),
            tlsMs: intMs(obj, "tlsMs")
        )
    }

    private static func intMs(_ obj: [String: Any], _ key: String) -> Int? {
        let v = (obj[key] as? Int) ?? (obj[key] as? NSNumber)?.intValue
        return v.flatMap { $0 >= 0 ? $0 : nil }
    }

    static func encodeCache(_ map: [String: ServerReachState]) -> String {
        var root: [String: Any] = [:]
        for (id, state) in map {
            if let json = state.toCacheJSON() { root[id] = json }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    static func decodeCache(_ json: String) -> [String: ServerReachState] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: ServerReachState] = [:]
        for (key, value) in root {
            guard let obj = value as? [String: Any], let state = fromCacheJSON(obj) else { continue }
            out[key] = state
        }
        return out
    }
}

enum UplinkProbe {
    /// TCP + TLS; HY2 uses QUIC VN (salamander-wrapped when obfs is set). TCP RTT fallback for HY2.
    static func probe(_ profile: ServerProfile) async -> ServerReachState {
        let host = profile.connectPlan.uplinkHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .offline }
        let port = profile.uplinkPort
        let hy2 = profile.serverProtocol == .hysteria2
        let salamander: String? = {
            guard case .hysteria2(let p) = profile.profile else { return nil }
            return p.obfsPassword?.nilIfBlank
        }()
        async let tcp = PublicEgressDiagnostics.probeTcpMs(host, port: port)
        async let hs = hy2
            ? PublicEgressDiagnostics.probeQuicMs(host, port: port, salamanderPassword: salamander)
            : PublicEgressDiagnostics.probeTlsMs(host, port: port)
        // Sub-ms success floors to 1 — UI must never show ~0ms for a real probe.
        let tcpMs = clampRtt(await tcp)
        let hsMs = clampRtt(await hs)
        let pingMs = hsMs >= 0 ? hsMs : (hy2 && tcpMs >= 0 ? tcpMs : hsMs)
        let tcpText = tcpMs >= 0 ? "\(tcpMs)ms" : "fail"
        let hsText = hsMs >= 0 ? "\(hsMs)ms" : "fail"
        let pingText = pingMs >= 0 ? "\(pingMs)ms" : "fail"
        let hsLabel = hy2 ? "quic" : "tls"
        await MainActor.run {
            AppLog.shared.append(
                "InternetProbe \(host):\(port) tcp=\(tcpText) \(hsLabel)=\(hsText) ping=\(pingText)"
            )
        }
        return .fromProbes(tcpMs: tcpMs, tlsMs: pingMs)
    }

    private static func clampRtt(_ ms: Int) -> Int {
        ms < 0 ? ms : max(1, ms)
    }
}
