import Foundation

enum ServerReachStatus: String, Sendable {
    case checking
    case online
    case offline
}

struct ServerReachState: Equatable, Sendable {
    var status: ServerReachStatus
    /// TCP connect RTT ms.
    var latencyMs: Int?
    /// Handshake RTT: TLS (TCP protocols) or QUIC (HY2). Cache key `tlsMs` kept for compat.
    var tlsMs: Int?

    static let checking = ServerReachState(status: .checking)
    static let offline = ServerReachState(status: .offline)

    static func formatMs(_ ms: Int?) -> String {
        ms.map { "~\($0)ms" } ?? "n/a"
    }

    /// List ping label; empty when protocol has no meaningful uplink RTT.
    static func formatListLabel(_ state: ServerReachState, protocol proto: ServerProtocol) -> String {
        guard proto.showsUplinkPing else { return "" }
        return formatMs(state.tlsMs ?? state.latencyMs)
    }

    static func handshakeLabel(_ proto: ServerProtocol) -> String {
        proto == .hysteria2 ? "QUIC" : "TLS"
    }

    static func fromProbes(tcpMs: Int, handshakeMs: Int) -> ServerReachState {
        let tcpOk = tcpMs >= 0
        let hsOk = handshakeMs >= 0
        if !tcpOk && !hsOk { return .offline }
        return ServerReachState(
            status: .online,
            latencyMs: tcpOk ? tcpMs : nil,
            tlsMs: hsOk ? handshakeMs : nil
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
    /// List-ping uplink RTT. OpenFlux: Online without ms (local SOCKS).
    static func probe(_ profile: ServerProfile) async -> ServerReachState {
        if !profile.serverProtocol.showsUplinkPing {
            await MainActor.run { AppLog.shared.append("SessionProbe \(profile.id)=—") }
            return ServerReachState(status: .online)
        }
        let host = profile.profile.dialHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            await MainActor.run { AppLog.shared.append("SessionProbe \(profile.id)=fail") }
            return .offline
        }
        let port = UInt16(clamping: profile.profile.dialPort)
        let hy2 = profile.serverProtocol == .hysteria2
        let salamander: String? = {
            guard case .hysteria2(let p) = profile.profile else { return nil }
            return p.obfsPassword?.nilIfBlank
        }()
        async let tcp = PublicEgressDiagnostics.probeTcpMs(host, port: port)
        async let hs = hy2
            ? PublicEgressDiagnostics.probeQuicMs(host, port: port, salamanderPassword: salamander)
            : PublicEgressDiagnostics.probeTlsMs(host, port: port)
        let tcpMs = clampRtt(await tcp)
        let hsMs = clampRtt(await hs)
        let pingMs = hsMs >= 0 ? hsMs : (hy2 && tcpMs >= 0 ? tcpMs : hsMs)
        let state = ServerReachState.fromProbes(tcpMs: tcpMs, handshakeMs: pingMs)
        let ms = state.tlsMs ?? state.latencyMs
        await MainActor.run {
            AppLog.shared.append("SessionProbe \(profile.id)=\(ms.map(String.init) ?? "fail")")
        }
        return state
    }

    private static func clampRtt(_ ms: Int) -> Int {
        ms < 0 ? ms : max(1, ms)
    }
}
