import Foundation
import NetworkExtension

extension VpnSharedStore {
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
    throughputWriteLock.lock()
    let now = Date()
    if let last = lastThroughputWritten,
       last.up == up, last.down == down,
       now.timeIntervalSince(last.at) < throughputWriteMinInterval
    {
      throughputWriteLock.unlock()
      return
    }
    lastThroughputWritten = (up, down, now)
    throughputWriteLock.unlock()
    do {
      let body: [String: Any] = [
        "up": up,
        "down": down,
        "updatedAt": throughputISO8601.string(from: now),
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
    throughputWriteLock.lock()
    lastThroughputWritten = nil
    throughputWriteLock.unlock()
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

  static func extensionHeartbeatURL() throws -> URL {
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
}
