import Foundation

/// Host-only hooks registered at app launch (Packet Tunnel / Controls leave nil).
enum VpnHostHooks {
  /// Ensure OpenFlux SOCKS is up before NE reconnect that needs the sidecar.
  static var ensureOpenFluxForReconnect: (() throws -> Void)?
}
