import Foundation
import NetworkExtension

extension VpnTunnelController {
  /// Removes saved VPN configurations for this packet-tunnel (host app only).
  func removeAllDemarVPNProfiles(completion: @escaping () -> Void) {
    performNEMutation { [weak self] done in
      NETunnelProviderManager.loadAllFromPreferences { managers, _ in
        let ours = managers?.filter { manager in
          (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == Self.packetTunnelBundleId
        } ?? []
        guard !ours.isEmpty else {
          done()
          DispatchQueue.main.async { completion() }
          return
        }
        let group = DispatchGroup()
        for manager in ours {
          group.enter()
          manager.removeFromPreferences { _ in group.leave() }
        }
        group.notify(queue: .main) {
          done()
          self?.invalidateCachedManager()
          completion()
        }
      }
    }
  }

  /// Sign-out / session revoke: stop tunnel, wipe App Group connect files, remove NE profile
  /// so system VPN / Control Center cannot reconnect without auth.
  func revokeAccess(completion: @escaping () -> Void) {
    cancelConnectOperation()
    Self.setControlState("disconnecting")
    loadTunnelManager { [weak self] result in
      guard let self else {
        VpnSharedStore.clearConnectArtifacts()
        completion()
        return
      }
      if case .success(let manager?) = result {
        let status = manager.connection.status
        if status != .disconnected, status != .invalid {
          let sessionId = self.extractSessionId(from: manager)
            ?? VpnSharedStore.loadActiveSession()?["sessionId"]
          VpnSharedStore.setPendingStopContext(triggerSource: "signOut", sessionId: sessionId)
          manager.connection.stopVPNTunnel()
        }
      }
      VpnSharedStore.clearConnectArtifacts()
      self.removeAllDemarVPNProfiles {
        Self.setControlState("disconnected")
        completion()
      }
    }
  }

  func disconnect(completion: @escaping (Result<Void, Error>) -> Void) {
    disconnect(triggerSource: "hostAppDisconnect", completion: completion)
  }

  func disconnect(
    triggerSource: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    cancelConnectOperation()
    Self.setControlState("disconnecting")
    loadTunnelManager { result in
      switch result {
      case let .failure(error):
        Self.setControlState("error")
        completion(.failure(error))
      case let .success(manager):
        guard let manager else {
          Self.setControlState("disconnected")
          completion(.success(()))
          return
        }

        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        self.performNEMutation { done in
          manager.saveToPreferences { error in
            defer { done() }
            DispatchQueue.main.async {
              if let error {
                Self.setControlState("error")
                completion(.failure(error))
                return
              }
              let sessionId = self.extractSessionId(from: manager) ?? VpnSharedStore.loadActiveSession()?["sessionId"]
              VpnSharedStore.setPendingStopContext(triggerSource: triggerSource, sessionId: sessionId)
              manager.connection.stopVPNTunnel()
              VpnSharedStore.clearExtensionHeartbeat()
              VpnSharedStore.clearTunnelStartFailure()
              Self.setControlState("disconnected")
              completion(.success(()))
            }
          }
        }
      }
    }
  }
}
