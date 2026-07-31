import Foundation
import NetworkExtension

struct VpnConnectPayload: Codable {
  let configJson: String
  let uplinkHost: String?
  let updatedAt: Date
}

enum VpnSharedStore {
  private static let payloadFile = "last_connect_payload.json"
  private static let stateFile = "control_state.json"
  private static let pendingUiDiagFile = "pending_ui_diag.log"
  private static let journalFile = "vpn_journal.log"
  static let journalMaxLines = 512
  private static let journalOffsetKey = "demar_journal_vpn_bytes"
  private static let stopReasonFile = "last_stop_reason.json"
  private static let stopReasonHistoryFile = "stop_reason_history.log"
  private static let activeSessionFile = "active_session.json"
  private static let pendingStopContextFile = "pending_stop_context.json"
  private static let tunnelStartErrorFile = "last_tunnel_start_error.json"
  private static let extensionHeartbeatFile = "extension_heartbeat.json"
  private static let throughputFile = "throughput.json"
  private static let stopReasonHistoryLimit = 32
  private static let throughputISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let coreJournalImportQueue = DispatchQueue(label: "com.demar.vpn.coreJournalImport")
  private static let journalAppendQueue = DispatchQueue(label: "com.demar.vpn.journalAppend", qos: .utility)
  private static let exportMirrorQueue = DispatchQueue(label: "com.demar.vpn.exportMirror", qos: .utility)
  private static let exportMirrorLock = NSLock()
  private static var exportMirrorWork: DispatchWorkItem?
  private static let journalOffsetCore = "demar_journal_core_bytes"
  private static let firstImportTailBytes: Int64 = 64 * 1024
  private static let coreMirrorTailBytes: Int64 = 1024 * 1024
  private static let incrementalImportMaxBytes = 64 * 1024
  private static let incrementalImportMaxLines = 64

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

  static func saveTunnelStartFailure(_ message: String) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let body: [String: Any] = [
        "message": trimmed,
        "updatedAt": ISO8601DateFormatter().string(from: Date()),
      ]
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try tunnelStartErrorURL(), options: [.atomic])
    } catch {}
  }

  static func throughputURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(throughputFile, isDirectory: false)
  }

  static func saveThroughput(up: Int64, down: Int64) {
    do {
      let body: [String: Any] = [
        "up": up,
        "down": down,
        "updatedAt": throughputISO8601.string(from: Date()),
      ]
      try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        .write(to: try throughputURL(), options: [.atomic])
    } catch {}
  }

  /// Instantaneous Clash `/traffic` rates (B/s). Nil when missing or older than `maxAge`.
  static func readThroughput(maxAge: TimeInterval = 3) -> (up: Int64, down: Int64)? {
    guard let data = try? Data(contentsOf: throughputURL()),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let up: Int64? = (obj["up"] as? NSNumber)?.int64Value ?? (obj["up"] as? Int).map(Int64.init)
    let down: Int64? = (obj["down"] as? NSNumber)?.int64Value ?? (obj["down"] as? Int).map(Int64.init)
    guard let up, let down else { return nil }
    if let raw = obj["updatedAt"] as? String, !raw.isEmpty {
      let date = throughputISO8601.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
      if let date, Date().timeIntervalSince(date) > maxAge { return nil }
    }
    return (up, down)
  }

  static func clearThroughput() {
    try? FileManager.default.removeItem(at: throughputURL())
  }

  static func saveExtensionHeartbeat(phase: String) {
    let trimmed = phase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let phaseChanged = extensionHeartbeatPhase() != trimmed
    do {
      let body: [String: Any] = [
        "phase": trimmed,
        "updatedAt": ISO8601DateFormatter().string(from: Date()),
      ]
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try extensionHeartbeatURL(), options: [.atomic])
      if phaseChanged { VpnStatusSignal.post() }
    } catch {
      NSLog("[DemarVpn] saveExtensionHeartbeat failed: %@", String(describing: error))
    }
  }

  static func extensionHeartbeatPhase() -> String? {
    extensionHeartbeatSnapshot()?["phase"]
  }

  private static let heartbeatISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  /// Extension recently reported a live tunnel phase (running / core-started).
  static func extensionSignalsAlive(maxAge: TimeInterval = 60) -> Bool {
    extensionHeartbeatIsFresh(maxAge: maxAge)
  }

  static func extensionHeartbeatIsFresh(maxAge: TimeInterval = 60) -> Bool {
    guard let snapshot = extensionHeartbeatSnapshot() else { return false }
    let phase = snapshot["phase"]?.lowercased() ?? ""
    guard phase == "running" || phase == "core-started" || phase.hasPrefix("running") else {
      return false
    }
    guard let raw = snapshot["updatedAt"], !raw.isEmpty else { return true }
    let date = heartbeatISO8601.date(from: raw)
      ?? ISO8601DateFormatter().date(from: raw)
    guard let date else { return true }
    return Date().timeIntervalSince(date) <= maxAge
  }

  static func extensionHeartbeatSnapshot() -> [String: String]? {
    do {
      let url = try extensionHeartbeatURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let phase = (json["phase"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let updatedAt = (json["updatedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !phase.isEmpty else { return nil }
      return [
        "phase": phase,
        "updatedAt": updatedAt,
      ]
    } catch {
      return nil
    }
  }

  static func clearExtensionHeartbeat() {
    do {
      let url = try extensionHeartbeatURL()
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {}
  }

  private static func extensionHeartbeatURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(extensionHeartbeatFile, isDirectory: false)
  }

  static func clearTunnelStartFailure() {
    do {
      let url = try tunnelStartErrorURL()
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {}
  }

  static func drainTunnelStartFailureAndClear() -> String? {
    do {
      let url = try tunnelStartErrorURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      try FileManager.default.removeItem(at: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return message.isEmpty ? nil : message
    } catch {
      return nil
    }
  }

  static func readTunnelStartFailureSnapshot() -> String? {
    do {
      let url = try tunnelStartErrorURL()
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return message.isEmpty ? nil : message
    } catch {
      return nil
    }
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

  static func loadConnectPayload() throws -> VpnConnectPayload? {
    let url = try payloadURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(VpnConnectPayload.self, from: data)
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

  /// Persistent connect journal (app + extension). Survives drain of pending_ui_diag.
  static func appendJournalLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    let stamped = DemarLogTime.journalLine(trimmed)
    appendJournalLineRaw(stamped)
  }

  private static func appendJournalLineRaw(_ stamped: String) {
    journalAppendQueue.async {
      do {
        let url = try journalURL()
        try VpnSharedLineFile.appendLine(stamped, to: url, maxLines: journalMaxLines)
      } catch {
        NSLog("[DemarVpn] appendJournal failed: %@", String(describing: error))
      }
    }
  }

  static func journalURL() throws -> URL {
    try vpnDirectoryURL().appendingPathComponent(journalFile, isDirectory: false)
  }

  /// Host Documents mirror — `devicectl` cannot pull `demar_vpn/` from App Group (CoreDevice).
  static func syncExportMirror() {
    guard Bundle.main.bundleIdentifier == VpnAppGroup.hostBundleId,
          let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    let dir = docs.appendingPathComponent("demar", isDirectory: true)
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let src = try journalURL()
      guard fm.fileExists(atPath: src.path) else { return }
      let dst = dir.appendingPathComponent("demar_app.log")
      if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
      try fm.copyItem(at: src, to: dst)
      let core = try VpnAppGroup.coreLogFileURL()
      let coreMirror = dir.appendingPathComponent("core.log")
      if fm.fileExists(atPath: core.path) {
        try mirrorTail(from: core, to: coreMirror, maxBytes: coreMirrorTailBytes)
      } else if fm.fileExists(atPath: coreMirror.path) {
        try fm.removeItem(at: coreMirror)
      }
    } catch {
      NSLog("[DemarVpn] syncExportMirror failed: %@", String(describing: error))
    }
  }

  static func scheduleExportMirror() {
    guard Bundle.main.bundleIdentifier == VpnAppGroup.hostBundleId else { return }
    exportMirrorLock.lock()
    exportMirrorWork?.cancel()
    let work = DispatchWorkItem { syncExportMirror() }
    exportMirrorWork = work
    exportMirrorLock.unlock()
    exportMirrorQueue.asyncAfter(deadline: .now() + 1, execute: work)
  }

  private static func mirrorTail(from source: URL, to destination: URL, maxBytes: Int64) throws {
    let sourceHandle = try FileHandle(forReadingFrom: source)
    defer { try? sourceHandle.close() }
    let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
    try sourceHandle.seek(toOffset: UInt64(max(0, size - maxBytes)))
    let data = try sourceHandle.readToEnd() ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    let sessionText = text.range(of: "[demar-session]", options: .backwards)
      .map { String(text[$0.lowerBound...]) } ?? text
    try Data(sessionText.utf8).write(to: destination, options: [.atomic])
  }

  /// New journal lines since the previous import (byte offset in App Group UserDefaults).
  static func readIncrementalJournalLines() -> [String] {
    coreJournalImportQueue.sync {
      guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return [] }
      do {
        return newUtf8LinesSinceLastImport(
          url: try journalURL(),
          offsetKey: journalOffsetKey,
          ud: ud
        )
      } catch {
        return []
      }
    }
  }

  static func recentJournalLines(_ maxLines: Int) -> [String] {
    guard maxLines > 0 else { return [] }
    do {
      let url = try journalURL()
      let lines = try VpnSharedLineFile.readTrimmedLines(from: url)
      return Array(lines.suffix(maxLines))
    } catch {
      return []
    }
  }

  /// Queued diagnostics; also mirrored into the persistent journal.
  static func appendPendingUiDiagLine(_ line: String) {
    appendJournalLine(line)
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(pendingUiDiagFile, isDirectory: false)
      try VpnSharedLineFile.appendLine(trimmed, to: url, maxLines: 256)
    } catch {
      NSLog("[DemarVpn] appendPendingUiDiag failed: %@", String(describing: error))
    }
  }

  static func drainPendingUiDiagLinesAndClear() -> [String] {
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(pendingUiDiagFile, isDirectory: false)
      return try VpnSharedLineFile.drainLinesAndDelete(from: url)
    } catch {
      return []
    }
  }

  /// Drains recent PacketTunnel stop events ring-buffer persisted in App Group.
  static func drainTunnelStopReasonHistoryAndClear() -> [String] {
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(stopReasonHistoryFile, isDirectory: false)
      return try VpnSharedLineFile.drainLinesAndDelete(from: url)
    } catch {
      return []
    }
  }

  /// New UTF-8 lines appended to shared core logs since the last call (App Group byte offsets). First call skips backlog.
  static func readIncrementalSharedCoreLogLines() -> [String] {
    coreJournalImportQueue.sync {
      guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return [] }
      do {
        return newUtf8LinesSinceLastImport(
          url: try VpnAppGroup.coreLogFileURL(),
          offsetKey: journalOffsetCore,
          ud: ud
        )
      } catch {
        return []
      }
    }
  }

  /// Best-effort snapshot of the last non-empty UTF-8 line from shared core log.
  static func readLastCoreErrorLineSnapshot() -> String? {
    do {
      let url = try VpnAppGroup.coreLogFileURL()
      let path = url.path
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 64 * 1024 ? size - 64 * 1024 : 0)
      let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
      let line = text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .last
      guard let line, !line.isEmpty else { return nil }
      return line
    } catch {
      return nil
    }
  }

  private static func newUtf8LinesSinceLastImport(url: URL, offsetKey: String, ud: UserDefaults) -> [String] {
    let path = url.path
    if !FileManager.default.fileExists(atPath: path) {
      ud.removeObject(forKey: offsetKey)
      return []
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

    if ud.object(forKey: offsetKey) == nil {
      let initialOffset = max(0, fileSize - firstImportTailBytes)
      ud.set(NSNumber(value: initialOffset), forKey: offsetKey)
    }

    var offset = (ud.object(forKey: offsetKey) as? NSNumber)?.int64Value ?? 0
    if fileSize < offset {
      offset = 0
      ud.set(NSNumber(value: 0), forKey: offsetKey)
    }
    if offset >= fileSize { return [] }

    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      return []
    }
    defer { try? handle.close() }

    let remaining = Int(fileSize - offset)
    let readLimit = min(remaining, incrementalImportMaxBytes)
    let chunk: Data
    do {
      try handle.seek(toOffset: UInt64(offset))
      guard let c = try handle.read(upToCount: readLimit), !c.isEmpty else { return [] }
      chunk = c
    } catch {
      return []
    }

    guard let nlIdx = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
    let complete = chunk[..<chunk.index(after: nlIdx)]
    guard let text = String(data: Data(complete), encoding: .utf8) else { return [] }

    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if lines.count > incrementalImportMaxLines {
      lines = Array(lines.suffix(incrementalImportMaxLines))
    }

    ud.set(NSNumber(value: offset + Int64(complete.count)), forKey: offsetKey)
    return lines
  }

  private static func appendTunnelStopReasonHistoryLine(_ line: String) {
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
