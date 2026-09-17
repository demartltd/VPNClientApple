import Foundation
import NetworkExtension

extension VpnTunnelController {
  func waitForTunnelReadiness(
    manager: NETunnelProviderManager,
    deadline: Date,
    operationGeneration: UInt64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard isCurrentConnectOperation(operationGeneration) else { return }
    let status = manager.connection.status
    let heartbeat = VpnSharedStore.extensionHeartbeatPhase() ?? ""
    if status == .connected, heartbeat == "running" || heartbeat == "core-started" {
      Self.setControlState("connected")
      completion(.success(()))
      return
    }
    if let message = VpnTunnelReadiness.failureMessage(
      heartbeat: heartbeat,
      startFailure: VpnSharedStore.readTunnelStartFailureSnapshot()
    ) {
      diag("readiness failed early: status=\(Self.statusLabel(status)) heartbeat=\(heartbeat.isEmpty ? "none" : heartbeat)")
      Self.setControlState("error")
      completion(.failure(NSError(domain: "DemarVpn", code: 44, userInfo: [
        NSLocalizedDescriptionKey: message,
      ])))
      return
    }
    if Date() >= deadline || status == .invalid {
      let message = "VPN data path did not become ready within 70 seconds."
      diag("readiness failed: status=\(Self.statusLabel(status)) heartbeat=\(heartbeat.isEmpty ? "none" : heartbeat)")
      manager.connection.stopVPNTunnel()
      Self.setControlState("error")
      completion(.failure(NSError(domain: "DemarVpn", code: 45, userInfo: [
        NSLocalizedDescriptionKey: message,
      ])))
      return
    }
    let work = DispatchWorkItem { [weak self] in
      self?.waitForTunnelReadiness(
        manager: manager,
        deadline: deadline,
        operationGeneration: operationGeneration,
        completion: completion
      )
    }
    connectStateLock.lock()
    readinessWorkItem?.cancel()
    readinessWorkItem = work
    connectStateLock.unlock()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  /// Waits until NE is idle after `stopVPNTunnel` (Apple: stop returns immediately).
  func waitUntilDisconnected(timeout: TimeInterval = 10, completion: @escaping (Bool) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    func poll() {
      currentStatus { status in
        if status == .disconnected || status == .invalid {
          completion(true)
          return
        }
        if Date() >= deadline {
          completion(false)
          return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
      }
    }
    poll()
  }
}
