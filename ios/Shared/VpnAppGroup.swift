import Foundation

enum VpnAppGroup {
  static let id = "group.com.demar.adblock"
  /// Host app bundle (not Packet Tunnel / Controls) — Documents export mirror for `scripts/journal.sh`.
  static let hostBundleId = "com.demar.adblock"

  static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
  }

  static func sharedDirectoryURL() throws -> URL {
    guard let base = containerURL else {
      throw NSError(
        domain: "DemarVpn",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable (\(id))."]
      )
    }
    return base
  }

  static func configURL() throws -> URL {
    try sharedDirectoryURL().appendingPathComponent("demar_vpn/config.json", isDirectory: false)
  }

  static func assetDirectoryURL() throws -> URL {
    try sharedDirectoryURL().appendingPathComponent("demar_vpn/core_assets", isDirectory: true)
  }

  static func coreLogFileURL() throws -> URL {
    try sharedDirectoryURL().appendingPathComponent("demar_vpn/core.log", isDirectory: false)
  }
}

enum CoreBundleAssets {
  static let subdirectories = ["singbox", "singbox_macos", "RuleSets"]
  static let geoFiles = ["geoip.db", "geosite.db"]
  /// Basename == rule-set tag + `.srs` (sync script / libbox `workingPath`).
  static let adsFile = "geosite-category-ads.srs"
  static let adsRuleSetTag = "geosite-category-ads"
  static let runtimeFiles = geoFiles + ["bundled_version.txt"]

  static func bundledURL(for filename: String) -> URL? {
    let base = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    if let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) {
      return url
    }
    for sub in subdirectories {
      if let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext, subdirectory: sub) {
        return url
      }
    }
    return nil
  }

  static func fileSize(_ name: String, in directory: URL) -> Int64 {
    let path = directory.appendingPathComponent(name).path
    guard FileManager.default.fileExists(atPath: path) else { return -1 }
    return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
  }

  static func copyGeoIfPresent(to destinationDir: URL) throws {
    let fm = FileManager.default
    for name in runtimeFiles {
      guard let src = bundledURL(for: name) else { continue }
      let dst = destinationDir.appendingPathComponent(name)
      if fm.fileExists(atPath: dst.path) {
        if name == "bundled_version.txt",
           (try? Data(contentsOf: src)) == (try? Data(contentsOf: dst))
        {
          continue
        }
        let sourceSize = (try? fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value
        let destinationSize = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value
        if name != "bundled_version.txt", sourceSize == destinationSize { continue }
        try fm.removeItem(at: dst)
      }
      try fm.copyItem(at: src, to: dst)
    }
  }

  /// Copy bundled ads `.srs` into App Group `core_assets`.
  /// Returns relative basename for sing-box (`workingPath` = `core_assets`).
  static func ensureAds(in destinationDir: URL) -> String? {
    let fm = FileManager.default
    let dst = destinationDir.appendingPathComponent(adsFile)
    if let src = bundledURL(for: adsFile) {
      do {
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let sourceSize = (try? fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize > 0 else { return nil }
        let destinationSize = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value
        if destinationSize != sourceSize {
          if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
          try fm.copyItem(at: src, to: dst)
        }
      } catch {
        return nil
      }
    }
    return fileSize(adsFile, in: destinationDir) > 0 ? adsFile : nil
  }

  static func hasGeo(in directory: URL) -> Bool {
    geoFiles.allSatisfy { fileSize($0, in: directory) > 0 }
  }

  /// True when App Group geo is missing or `bundled_version.txt` differs from the host bundle
  /// (including after `AppRuntimeUpgrade.wipeStaleRuntime`, which deletes the version file).
  static func needsRefresh(in directory: URL) -> Bool {
    if !hasGeo(in: directory) { return true }
    guard let bundled = bundledURL(for: "bundled_version.txt"),
          let bundledData = try? Data(contentsOf: bundled)
    else { return true }
    let existing = try? Data(contentsOf: directory.appendingPathComponent("bundled_version.txt"))
    return existing != bundledData
  }
}
