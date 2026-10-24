import Foundation

/// OpenFlux SOCKS is started by the **host app** (`OpenFluxHostProcess`).
/// Packet Tunnel only waits for loopback SOCKS — must not spawn or link liboflux
/// (NE blocks spawn; second Go runtime next to Libbox aborts the appex).
enum OpenFluxSidecar {
  static func start(config: VpnSharedStore.OpenFluxSidecarConfig) throws {
    let (host, port) = LoopbackPortWait.normalizedSocks(
      host: config.socksHost,
      port: config.socksPort
    )
    let socks = "\(host):\(port)"
    NSLog("[DemarPacketTunnel] [ofx] wait host socks=%@", socks)
    guard LoopbackPortWait.ready(
      host: host,
      port: port,
      timeoutMs: LoopbackPortWait.tunnelWaitTimeoutMs
    ) else {
      throw NSError(
        domain: "OpenFluxSidecar",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "OpenFlux SOCKS not ready on \(socks) (host process)"]
      )
    }
    NSLog("[DemarPacketTunnel] [ofx] host socks ready")
  }
}
