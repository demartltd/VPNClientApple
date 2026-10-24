import Foundation
import NetworkExtension

struct VpnConnectPayload: Codable {
  let configJson: String
  let uplinkHost: String?
  let updatedAt: Date
}

enum VpnSharedStore {
  static let payloadFile = "last_connect_payload.json"
  static let bypassGeoipTagsFile = "bypass_geoip_tags.json"
  static let openFluxSidecarFile = "openflux_sidecar.json"
  static let stateFile = "control_state.json"
  static let pendingUiDiagFile = "pending_ui_diag.log"
  static let journalFile = "vpn_journal.log"
  static let journalMaxLines = 512
  static let journalOffsetKey = "demar_journal_vpn_bytes"
  static let stopReasonFile = "last_stop_reason.json"
  static let stopReasonHistoryFile = "stop_reason_history.log"
  static let activeSessionFile = "active_session.json"
  static let pendingStopContextFile = "pending_stop_context.json"
  static let tunnelStartErrorFile = "last_tunnel_start_error.json"
  static let extensionHeartbeatFile = "extension_heartbeat.json"
  static let throughputFile = "throughput.json"
  static let stopReasonHistoryLimit = 32
  static let throughputWriteMinInterval: TimeInterval = 2
  static let throughputISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  static let throughputWriteLock = NSLock()
  static var lastThroughputWritten: (up: Int64, down: Int64, at: Date)?

  static let coreJournalImportQueue = DispatchQueue(label: "com.demar.adblock.coreJournalImport")
  static let journalAppendQueue = DispatchQueue(label: "com.demar.adblock.journalAppend", qos: .utility)
  static let exportMirrorQueue = DispatchQueue(label: "com.demar.adblock.exportMirror", qos: .utility)
  static let exportMirrorLock = NSLock()
  static var exportMirrorWork: DispatchWorkItem?
  static let journalOffsetCore = "demar_journal_core_bytes"
  static let firstImportTailBytes: Int64 = 64 * 1024
  static let coreMirrorTailBytes: Int64 = 1024 * 1024
  static let incrementalImportMaxBytes = 64 * 1024
  static let incrementalImportMaxLines = 64

  static func vpnDirectoryURL() throws -> URL {
    let vpnDir = try VpnAppGroup.sharedDirectoryURL().appendingPathComponent("demar_vpn", isDirectory: true)
    try FileManager.default.createDirectory(at: vpnDir, withIntermediateDirectories: true)
    return vpnDir
  }

  static func payloadURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(payloadFile, isDirectory: false)
  }

  static func stateURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(stateFile, isDirectory: false)
  }

  static func stopReasonURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(stopReasonFile, isDirectory: false)
  }

  static func activeSessionURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(activeSessionFile, isDirectory: false)
  }

  static func pendingStopContextURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(pendingStopContextFile, isDirectory: false)
  }

  static func tunnelStartErrorURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(tunnelStartErrorFile, isDirectory: false)
  }

  static func saveConnectPayload(configJson: String, uplinkHost: String?) throws {
    let payload = VpnConnectPayload(
      configJson: configJson,
      uplinkHost: uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines),
      updatedAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: try payloadURL(), options: [.atomic])
  }

  struct OpenFluxSidecarConfig: Codable, Equatable {
    let link: String
    let socksHost: String
    let socksPort: Int
  }

  static func saveOpenFluxSidecar(link: String, socksHost: String, socksPort: Int) throws {
    let cfg = OpenFluxSidecarConfig(
      link: link.trimmingCharacters(in: .whitespacesAndNewlines),
      socksHost: socksHost.trimmingCharacters(in: .whitespacesAndNewlines),
      socksPort: socksPort
    )
    let data = try JSONEncoder().encode(cfg)
    try data.write(
      to: try vpnDirectoryURL().appendingPathComponent(openFluxSidecarFile, isDirectory: false),
      options: [.atomic]
    )
  }

  static func loadOpenFluxSidecar() -> OpenFluxSidecarConfig? {
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(openFluxSidecarFile, isDirectory: false)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try JSONDecoder().decode(OpenFluxSidecarConfig.self, from: Data(contentsOf: url))
    } catch {
      return nil
    }
  }

  static func clearOpenFluxSidecar() {
    guard let url = try? vpnDirectoryURL().appendingPathComponent(openFluxSidecarFile, isDirectory: false)
    else { return }
    try? FileManager.default.removeItem(at: url)
  }

  static func saveBypassGeoipTags(_ tags: [String]) throws {
    var seen = Set<String>()
    let unique = tags.compactMap { raw -> String? in
      let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard tag.hasPrefix("geoip"), seen.insert(tag).inserted else { return nil }
      return tag
    }
    let data = try JSONSerialization.data(withJSONObject: unique, options: [.sortedKeys])
    try data.write(
      to: try vpnDirectoryURL().appendingPathComponent(bypassGeoipTagsFile, isDirectory: false),
      options: [.atomic]
    )
  }

  static func loadBypassGeoipTags() -> [String] {
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(bypassGeoipTagsFile, isDirectory: false)
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      let data = try Data(contentsOf: url)
      return (try JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    } catch {
      return []
    }
  }

  static func loadConnectPayload() throws -> VpnConnectPayload? {
    let url = try payloadURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(VpnConnectPayload.self, from: data)
  }

  /// Wipes reconnect material so Control Center / Settings cannot start a tunnel after sign-out.
  static func clearConnectArtifacts() {
    let fm = FileManager.default
    for url in [try? payloadURL(), try? VpnAppGroup.configURL()].compactMap({ $0 }) {
      try? fm.removeItem(at: url)
    }
    clearOpenFluxSidecar()
    clearActiveSession()
    clearThroughput()
    clearExtensionHeartbeat()
    clearTunnelStartFailure()
    saveControlState("disconnected")
  }

  /// - Parameter notify: Post Darwin signal for cross-process UI sync (extension only; host uses `false`).
  static func saveControlState(_ state: String, notify: Bool = true) {
    if loadControlState() == state { return }
    do {
      let body = ["state": state, "updatedAt": ISO8601DateFormatter().string(from: Date())]
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try stateURL(), options: [.atomic])
      if notify { VpnStatusSignal.post() }
    } catch {
      // Best effort cache for controls; ignore write failures.
    }
  }

  static func loadControlState() -> String? {
    do {
      let url = try stateURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      return json["state"] as? String
    } catch {
      return nil
    }
  }

  /// Clears App Group control cache when the system reports no active tunnel.
  static func clearStaleControlState() {
    reconcileControlState(with: .disconnected)
  }

  /// Aligns persisted control state with `NEVPNConnection.status` (NE is authoritative when disconnected).
  static func reconcileControlState(with neStatus: NEVPNStatus) {
    guard neStatus == .disconnected else { return }
    guard let raw = loadControlState()?.lowercased(), !raw.isEmpty else { return }
    switch raw {
    case "connected", "connecting", "disconnecting", "error":
      saveControlState("disconnected")
      if raw == "connected" || raw == "connecting" {
        clearExtensionHeartbeat()
      }
    default:
      break
    }
  }

  static func saveActiveSession(sessionId: String, triggerSource: String) {
    let cleanSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleanSession.isEmpty { return }
    let cleanSource = triggerSource.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = cleanSource.isEmpty ? "unknown" : cleanSource
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      let body: [String: Any] = [
        "sessionId": cleanSession,
        "triggerSource": source,
        "startedAt": now,
        "updatedAt": now,
      ]
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try activeSessionURL(), options: [.atomic])
    } catch {
      // Best effort metadata.
    }
  }

  static func loadActiveSession() -> [String: String]? {
    do {
      let url = try activeSessionURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let sessionId = (json["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if sessionId.isEmpty { return nil }
      let source = (json["triggerSource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let startedAt = (json["startedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let updatedAt = (json["updatedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return [
        "sessionId": sessionId,
        "triggerSource": source,
        "startedAt": startedAt,
        "updatedAt": updatedAt,
      ]
    } catch {
      return nil
    }
  }

  static func clearActiveSession() {
    do {
      let url = try activeSessionURL()
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {}
  }

  static func setPendingStopContext(triggerSource: String, sessionId: String?) {
    let source = triggerSource.trimmingCharacters(in: .whitespacesAndNewlines)
    if source.isEmpty { return }
    let cleanSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let now = ISO8601DateFormatter().string(from: Date())
      var body: [String: Any] = [
        "triggerSource": source,
        "updatedAt": now,
      ]
      if let cleanSession, !cleanSession.isEmpty {
        body["sessionId"] = cleanSession
      }
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try pendingStopContextURL(), options: [.atomic])
    } catch {}
  }

  static func consumePendingStopContext() -> [String: String]? {
    do {
      let url = try pendingStopContextURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      try FileManager.default.removeItem(at: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let source = (json["triggerSource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if source.isEmpty { return nil }
      let sessionId = (json["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let updatedAt = (json["updatedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return [
        "triggerSource": source,
        "sessionId": sessionId,
        "updatedAt": updatedAt,
      ]
    } catch {
      return nil
    }
  }

  static func saveLastTunnelStopReason(
    label: String,
    code: Int,
    sessionId: String?,
    triggerSource: String?,
    uptimeSinceStartSec: Int?
  ) {
    do {
      let updatedAt = ISO8601DateFormatter().string(from: Date())
      let journalAt = DemarLogTime.stamp()
      let body: [String: Any] = [
        "label": label,
        "code": code,
        "sessionId": sessionId ?? "",
        "triggerSource": triggerSource ?? "",
        "uptimeSinceStartSec": uptimeSinceStartSec ?? -1,
        "updatedAt": updatedAt,
      ]
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try stopReasonURL(), options: [.atomic])
      var parts = [
        "[ios] tunnel stop history: label=\(label)",
        "code=\(code)",
      ]
      if let triggerSource, !triggerSource.isEmpty {
        parts.append("source=\(triggerSource)")
      }
      if let sessionId, !sessionId.isEmpty {
        parts.append("session=\(sessionId)")
      }
      if let uptimeSinceStartSec, uptimeSinceStartSec >= 0 {
        parts.append("uptimeSec=\(uptimeSinceStartSec)")
      }
      parts.append("at=\(journalAt)")
      appendTunnelStopReasonHistoryLine(parts.joined(separator: " "))
    } catch {
      // Best effort diagnostics; ignore write failures.
    }
  }

  static func drainLastTunnelStopReasonAndClear() -> [String: String]? {
    do {
      let url = try stopReasonURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      try FileManager.default.removeItem(at: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let label = (json["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let code = (json["code"] as? Int) ?? (json["code"] as? NSNumber)?.intValue ?? -1
      let sessionId = (json["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let triggerSource = (json["triggerSource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let uptimeSinceStartSec = (json["uptimeSinceStartSec"] as? Int)
        ?? (json["uptimeSinceStartSec"] as? NSNumber)?.intValue
        ?? -1
      let updatedAt = (json["updatedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !label.isEmpty else { return nil }
      var out = [
        "label": label,
        "code": String(code),
        "updatedAt": updatedAt,
      ]
      if !sessionId.isEmpty {
        out["sessionId"] = sessionId
      }
      if !triggerSource.isEmpty {
        out["triggerSource"] = triggerSource
      }
      if uptimeSinceStartSec >= 0 {
        out["uptimeSinceStartSec"] = String(uptimeSinceStartSec)
      }
      return out
    } catch {
      return nil
    }
  }

  static func appendTunnelStopReasonHistoryLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(stopReasonHistoryFile, isDirectory: false)
      try VpnSharedLineFile.appendLine(trimmed, to: url, maxLines: stopReasonHistoryLimit)
    } catch {
      // Best effort history for diagnostics.
    }
  }
}

enum VpnSharedLineFile {
  static func readTrimmedLines(from url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func appendLine(
    _ line: String,
    to url: URL,
    maxLines: Int
  ) throws {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    let data = Data((trimmed + "\n").utf8)
    if FileManager.default.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: url, options: [.atomic])
    }

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size > max(16 * 1024, maxLines * 256) else { return }
    var lines = try readTrimmedLines(from: url)
    if lines.count > maxLines {
      lines = Array(lines.suffix(maxLines))
    }
    let out = (lines + [""]).joined(separator: "\n")
    try Data(out.utf8).write(to: url, options: [.atomic])
  }

  static func drainLinesAndDelete(from url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let lines = try readTrimmedLines(from: url)
    try FileManager.default.removeItem(at: url)
    return lines
  }
}

enum VpnReconfigurePolicy {
  /// With unchanged routes, only a confirmed restored path soft-restarts the core.
  /// Routine Wi-Fi/cellular flips stay sticky in the platform interface monitor;
  /// wake (every screen unlock) must not restart a healthy tunnel — a full service
  /// reload re-runs openTun/setTunnelNetworkSettings and aborts every active stream.
  static func shouldSoftRestartWhenRoutesUnchanged(reason: String) -> Bool {
    reason == "pathRecoveredAfterLoss"
  }
}

/// Path-loss arming for TunnelLifecycle: NE often reports `.unsatisfied` after full
/// routes while phys ifaces (en0) remain listed — that must not trigger soft-restart
/// (kills Hysteria2 + Telegram MTProto).
enum TunnelPathLossPolicy {
  static func shouldArmRecoveryAfterUnsatisfied(physicalInterfacesEmpty: Bool) -> Bool {
    physicalInterfacesEmpty
  }
}

/// Pure readiness helper (host + tests): start-failure file or extension `failed-*` heartbeat.
enum VpnTunnelReadiness {
  static func failureMessage(heartbeat: String, startFailure: String?) -> String? {
    if let startFailure, !startFailure.isEmpty { return startFailure }
    let phase = heartbeat.trimmingCharacters(in: .whitespacesAndNewlines)
    if phase.hasPrefix("failed") {
      return "VPN tunnel start failed (\(phase))."
    }
    return nil
  }
}
