import Foundation

/// OpenFlux SOCKS5 in the **host app** via in-process `liboflux` (same idea as Libbox).
/// iOS forbids `posix_spawn` in both the app and Packet Tunnel (EPERM).
enum OpenFluxHostProcess {
  static var isRunning: Bool { OpenFluxNative.isRunning() }

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
  }

  static func stop() {
    OpenFluxNative.stop()
  }

  private static func workDir() throws -> URL {
    let dir = try VpnAppGroup.sharedDirectoryURL().appendingPathComponent("openflux", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
