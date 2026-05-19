import Foundation

enum VpnAppGroup {
  static let id = "group.com.demar.vpn"

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
    try sharedDirectoryURL().appendingPathComponent("demar_vpn/xray_assets", isDirectory: true)
  }

  static func xrayErrorLogFileURL() throws -> URL {
    try sharedDirectoryURL().appendingPathComponent("demar_vpn/xray_error.log", isDirectory: false)
  }

  static func xrayAccessLogFileURL() throws -> URL {
    try sharedDirectoryURL().appendingPathComponent("demar_vpn/xray_access.log", isDirectory: false)
  }
}
