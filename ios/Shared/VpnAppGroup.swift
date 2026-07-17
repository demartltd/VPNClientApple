import Foundation

enum VpnAppGroup {
  static let id = "group.com.demar.vpn"
  /// Host app bundle (not Packet Tunnel / Controls) — Documents export mirror for `scripts/journal.sh`.
  static let hostBundleId = "com.demar.vpn"

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
  static let subdirectories = ["singbox", "singbox_macos"]
  static let geoFiles = ["geoip.db", "geosite.db"]

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

  static func copyGeoIfPresent(to destinationDir: URL) throws {
    let fm = FileManager.default
    for name in geoFiles {
      guard let src = bundledURL(for: name) else { continue }
      let dst = destinationDir.appendingPathComponent(name)
      if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
      try fm.copyItem(at: src, to: dst)
    }
  }

  static func hasGeo(in directory: URL) -> Bool {
    let fm = FileManager.default
    return geoFiles.allSatisfy { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
  }
}
