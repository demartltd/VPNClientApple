import Foundation
#if os(iOS)
import UIKit
#endif

/// OpenFlux SOCKS5 in the **host app** via in-process `liboflux` (same idea as Libbox).
/// iOS forbids `posix_spawn` in both the app and Packet Tunnel (EPERM).
enum OpenFluxHostProcess {
  static var isRunning: Bool { OpenFluxNative.isRunning() }

  #if os(iOS)
  private static var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  #endif

  /// Start SOCKS from App Group sidecar if present (Control Center / reconnect).
  static func ensureSidecarRunning() throws {
    guard let cfg = VpnSharedStore.loadOpenFluxSidecar() else { return }
    if isRunning {
      beginBackgroundKeepAlive()
      return
    }
    try start(link: cfg.link, socksHost: cfg.socksHost, socksPort: cfg.socksPort)
  }

  static func start(link: String, socksHost: String, socksPort: Int) throws {
    let decoded = try OpenFluxLink.decode(link)
    let work = try workDir()
    let cookiesURL = work.appendingPathComponent("cookies.json")
    let (host, port) = LoopbackPortWait.normalizedSocks(host: socksHost, port: socksPort)
    let socks = "\(host):\(port)"

    if let err = OpenFluxNative.startBoards(
      withURL: decoded.boardsUrl,
      secret: decoded.secret,
      socksHost: host,
      socksPort: Int32(port),
      cookieStore: cookiesURL.path
    ) {
      throw NSError(
        domain: "OpenFluxHostProcess",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: err]
      )
    }

    guard LoopbackPortWait.ready(
      host: host,
      port: port,
      timeoutMs: LoopbackPortWait.hostReadyTimeoutMs
    ) else {
      OpenFluxNative.stop()
      throw NSError(
        domain: "OpenFluxHostProcess",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "OpenFlux SOCKS not ready on \(socks)"]
      )
    }
    beginBackgroundKeepAlive()
  }

  static func stop() {
    OpenFluxNative.stop()
    endBackgroundKeepAlive()
  }

  /// Delay host suspend so in-process SOCKS stays up briefly after leaving foreground.
  static func beginBackgroundKeepAlive() {
    #if os(iOS)
    let apply = {
      guard backgroundTaskId == .invalid else { return }
      backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "demar.openflux.socks") {
        endBackgroundKeepAlive()
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    #endif
  }

  static func endBackgroundKeepAlive() {
    #if os(iOS)
    let apply = {
      guard backgroundTaskId != .invalid else { return }
      UIApplication.shared.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    #endif
  }

  private static func workDir() throws -> URL {
    let dir = try VpnAppGroup.sharedDirectoryURL().appendingPathComponent("openflux", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
