import Foundation

extension VpnSharedStore {
  static func appendJournalLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    let stamped = DemarLogTime.journalLine(trimmed)
    appendJournalLineRaw(stamped)
  }

  static func appendJournalLineRaw(_ stamped: String) {
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

  static func mirrorTail(from source: URL, to destination: URL, maxBytes: Int64) throws {
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

  static func newUtf8LinesSinceLastImport(url: URL, offsetKey: String, ud: UserDefaults) -> [String] {
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

}
