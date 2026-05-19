import Foundation

struct VpnConnectPayload: Codable {
  let configJson: String
  let uplinkHost: String?
  let updatedAt: Date
}

enum VpnSharedStore {
  private static let payloadFile = "last_connect_payload.json"
  private static let stateFile = "control_state.json"
  private static let pendingUiDiagFile = "pending_ui_diag.log"
  private static let stopReasonFile = "last_stop_reason.json"
  private static let stopReasonHistoryFile = "stop_reason_history.log"
  private static let activeSessionFile = "active_session.json"
  private static let pendingStopContextFile = "pending_stop_context.json"
  private static let stopReasonHistoryLimit = 32

  private static let xrayJournalImportQueue = DispatchQueue(label: "com.demar.vpn.xrayJournalImport")
  private static let journalOffsetXrayError = "demar_journal_xray_error_bytes"
  private static let journalOffsetXrayAccess = "demar_journal_xray_access_bytes"
  private static let firstImportTailBytes: Int64 = 64 * 1024

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

  static func saveControlState(_ state: String) {
    do {
      let body = ["state": state, "updatedAt": ISO8601DateFormatter().string(from: Date())]
      let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      try data.write(to: try stateURL(), options: [.atomic])
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
      parts.append("at=\(updatedAt)")
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

  /// Queued by Control Center / App Intents extension; drained into Flutter [AppLog] by the main app.
  static func appendPendingUiDiagLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    guard let data = (trimmed + "\n").data(using: .utf8) else { return }
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(pendingUiDiagFile, isDirectory: false)
      if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } else {
        try data.write(to: url, options: [.atomic])
      }
    } catch {}
  }

  static func drainPendingUiDiagLinesAndClear() -> [String] {
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(pendingUiDiagFile, isDirectory: false)
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      let text = try String(contentsOf: url, encoding: .utf8)
      try FileManager.default.removeItem(at: url)
      return text.split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    } catch {
      return []
    }
  }

  /// Drains recent PacketTunnel stop events ring-buffer persisted in App Group.
  static func drainTunnelStopReasonHistoryAndClear() -> [String] {
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(stopReasonHistoryFile, isDirectory: false)
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      let text = try String(contentsOf: url, encoding: .utf8)
      try FileManager.default.removeItem(at: url)
      return text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    } catch {
      return []
    }
  }

  /// New UTF-8 lines appended to shared xray logs since the last call (App Group byte offsets). First call skips backlog.
  static func readIncrementalSharedXrayLogLines() -> [String] {
    xrayJournalImportQueue.sync {
      guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return [] }
      var out: [String] = []
      do {
        out.append(contentsOf: newUtf8LinesSinceLastImport(
          url: try VpnAppGroup.xrayErrorLogFileURL(), offsetKey: journalOffsetXrayError, ud: ud))
        out.append(contentsOf: newUtf8LinesSinceLastImport(
          url: try VpnAppGroup.xrayAccessLogFileURL(), offsetKey: journalOffsetXrayAccess, ud: ud))
      } catch {}
      return out
    }
  }

  /// Best-effort snapshot of the last non-empty UTF-8 line from shared xray error log.
  static func readLastXrayErrorLineSnapshot() -> String? {
    do {
      let url = try VpnAppGroup.xrayErrorLogFileURL()
      let path = url.path
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      let text = try String(contentsOf: url, encoding: .utf8)
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

    let chunk: Data
    do {
      try handle.seek(toOffset: UInt64(offset))
      guard let c = try handle.read(upToCount: Int(fileSize - offset)), !c.isEmpty else { return [] }
      chunk = c
    } catch {
      return []
    }

    guard let nlIdx = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
    let complete = chunk[..<chunk.index(after: nlIdx)]
    guard let text = String(data: Data(complete), encoding: .utf8) else { return [] }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    ud.set(NSNumber(value: offset + Int64(complete.count)), forKey: offsetKey)
    return lines
  }

  private static func appendTunnelStopReasonHistoryLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    do {
      let url = try vpnDirectoryURL().appendingPathComponent(stopReasonHistoryFile, isDirectory: false)
      var lines: [String] = []
      if FileManager.default.fileExists(atPath: url.path) {
        let existing = try String(contentsOf: url, encoding: .utf8)
        lines = existing
          .split(separator: "\n", omittingEmptySubsequences: true)
          .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      }
      lines.append(trimmed)
      if lines.count > stopReasonHistoryLimit {
        lines.removeFirst(lines.count - stopReasonHistoryLimit)
      }
      let out = (lines + [""]).joined(separator: "\n")
      guard let data = out.data(using: .utf8) else { return }
      try data.write(to: url, options: [.atomic])
    } catch {
      // Best effort history for diagnostics.
    }
  }
}
