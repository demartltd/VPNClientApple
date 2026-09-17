import Foundation
import NetworkExtension

final class VpnTunnelController {
  static let shared = VpnTunnelController()
  static let packetTunnelBundleId = "com.demar.adblock.packet-tunnel"

  var connectInFlight = false
  var connectGeneration: UInt64 = 0
  var connectCancellation: (() -> Void)?
  var readinessWorkItem: DispatchWorkItem?
  let connectStateLock = NSLock()
  var cachedManager: NETunnelProviderManager?
  /// Serializes all NetworkExtension preference load/save/remove mutations.
  let neMutationQueue = DispatchQueue(label: "com.demar.adblock.neMutation")
  let runtimePrepQueue = DispatchQueue(label: "com.demar.adblock.runtimePrep", qos: .userInitiated)

  var isConnectInFlight: Bool {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    return connectInFlight
  }

  private init() {}

  /// Runs NE preference work one-at-a-time. `work` must invoke `done` exactly once.
  func performNEMutation(_ work: @escaping (_ done: @escaping () -> Void) -> Void) {
    neMutationQueue.async {
      let finished = DispatchSemaphore(value: 0)
      work { finished.signal() }
      _ = finished.wait(timeout: .now() + 90)
    }
  }

  static func isDemarManager(_ manager: NETunnelProviderManager) -> Bool {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
      return false
    }
    return proto.providerBundleIdentifier == packetTunnelBundleId
  }

  func diag(_ message: String) {
    #if os(macOS)
    VpnSharedStore.appendPendingUiDiagLine("[mac] \(message)")
    #else
    VpnSharedStore.appendPendingUiDiagLine("[ios] \(message)")
    #endif
  }

  func beginConnectOperation() -> UInt64? {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    if connectInFlight { return nil }
    connectGeneration &+= 1
    connectInFlight = true
    return connectGeneration
  }

  func completeConnectOperation(_ generation: UInt64) -> Bool {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    guard connectInFlight, connectGeneration == generation else { return false }
    connectInFlight = false
    connectCancellation = nil
    readinessWorkItem?.cancel()
    readinessWorkItem = nil
    VpnSharedStore.clearTunnelStartFailure()
    return true
  }

  func setConnectCancellation(_ generation: UInt64, _ cancellation: @escaping () -> Void) {
    connectStateLock.lock()
    if connectInFlight, connectGeneration == generation {
      connectCancellation = cancellation
    }
    connectStateLock.unlock()
  }

  /// Cancels an in-flight connect (UI error path / disconnect). Safe if idle.
  func cancelConnectOperation() {
    connectStateLock.lock()
    let cancellation = connectCancellation
    let wasInFlight = connectInFlight
    connectGeneration &+= 1
    connectInFlight = false
    connectCancellation = nil
    readinessWorkItem?.cancel()
    readinessWorkItem = nil
    connectStateLock.unlock()
    if wasInFlight { VpnSharedStore.clearTunnelStartFailure() }
    cancellation?()
  }

  func isCurrentConnectOperation(_ generation: UInt64) -> Bool {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    return connectInFlight && connectGeneration == generation
  }

  static func setControlState(_ state: String) {
    VpnSharedStore.saveControlState(state, notify: false)
    VpnControlReloader.reloadControls()
  }

  /// Reloads preferences and returns fresh Demar manager + `NEVPNConnection.status`.
  /// - Parameter reloadPreferences: When `false`, reads cached manager status only (safe during `startTunnel`).
  func refreshDemarStatus(
    reloadPreferences: Bool = true,
    completion: @escaping (Result<(manager: NETunnelProviderManager?, status: NEVPNStatus), Error>) -> Void
  ) {
    let finish: (Result<(NETunnelProviderManager?, NEVPNStatus), Error>) -> Void = { result in
      DispatchQueue.main.async {
        switch result {
        case let .success((manager, status)):
          completion(.success((manager: manager, status: status)))
        case let .failure(error):
          completion(.failure(error))
        }
      }
    }

    if !reloadPreferences, let cached = cachedManager {
      finish(.success((cached, cached.connection.status)))
      return
    }

    performNEMutation { [weak self] done in
      guard let self else {
        done()
        finish(.success((nil, .disconnected)))
        return
      }
      if let cached = self.cachedManager {
        cached.loadFromPreferences { error in
          defer { done() }
          if let error {
            self.cachedManager = nil
            finish(.failure(error))
            return
          }
          finish(.success((cached, cached.connection.status)))
        }
        return
      }

      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error {
          done()
          finish(.failure(error))
          return
        }
        let match = managers?.first(where: Self.isDemarManager)
        guard let match else {
          self.cachedManager = nil
          done()
          finish(.success((nil, .disconnected)))
          return
        }
        self.cachedManager = match
        match.loadFromPreferences { loadError in
          defer { done() }
          if let loadError {
            self.cachedManager = nil
            finish(.failure(loadError))
            return
          }
          finish(.success((match, match.connection.status)))
        }
      }
    }
  }

  func loadTunnelManager(completion: @escaping (Result<NETunnelProviderManager?, Error>) -> Void) {
    refreshDemarStatus { result in
      switch result {
      case let .success((manager, _)):
        completion(.success(manager))
      case let .failure(error):
        completion(.failure(error))
      }
    }
  }

  func currentStatus(completion: @escaping (NEVPNStatus) -> Void) {
    refreshDemarStatus { result in
      switch result {
      case let .success((_, status)):
        completion(status)
      case .failure:
        completion(.disconnected)
      }
    }
  }

  func invalidateCachedManager() {
    cachedManager = nil
  }

  /// Stops and cold-starts sing-box / Libbox in the packet-tunnel extension (tunnel must be connected).
  func hardRestartCore(completion: @escaping (Result<Void, Error>) -> Void) {
    sendProviderCommand("hardRestartCore", completion: completion)
  }

  func sendProviderCommand(_ command: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let payload = command.data(using: .utf8) else {
      completion(.failure(NSError(domain: "DemarVpn", code: 39, userInfo: [
        NSLocalizedDescriptionKey: String(localized: "Invalid command."),
      ])))
      return
    }
    refreshDemarStatus(reloadPreferences: false) { result in
      switch result {
      case let .failure(error):
        completion(.failure(error))
      case let .success((manager, status)):
        guard status == .connected || status == .reasserting else {
          completion(.failure(NSError(domain: "DemarVpn", code: 40, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "VPN is not connected."),
          ])))
          return
        }
        guard let session = manager?.connection as? NETunnelProviderSession else {
          completion(.failure(VpnTunnelError.noProviderSession))
          return
        }
        do {
          try session.sendProviderMessage(payload) { response in
            DispatchQueue.main.async {
              if let response,
                 let text = String(data: response, encoding: .utf8),
                 text.hasPrefix("err:")
              {
                completion(.failure(NSError(domain: "DemarVpn", code: 41, userInfo: [
                  NSLocalizedDescriptionKey: String(text.dropFirst(4)),
                ])))
              } else {
                completion(.success(()))
              }
            }
          }
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  /// Clears on-demand VPN rules so iOS does not auto-reconnect after an unexpected tunnel stop.
  func disableOnDemandAutoReconnect(completion: ((Error?) -> Void)? = nil) {
    loadTunnelManager { [weak self] result in
      switch result {
      case let .failure(error):
        self?.diag("onDemand check failed: \(error.localizedDescription)")
        DispatchQueue.main.async { completion?(error) }
      case let .success(manager):
        guard let manager else {
          self?.diag("onDemand check: no VPN profile")
          DispatchQueue.main.async { completion?(nil) }
          return
        }
        let rulesCount = manager.onDemandRules?.count ?? 0
        let enabled = manager.isOnDemandEnabled
        self?.diag("onDemand state: enabled=\(enabled) rules=\(rulesCount)")
        let hadOnDemand = enabled || rulesCount > 0
        guard hadOnDemand else {
          DispatchQueue.main.async { completion?(nil) }
          return
        }
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        self?.performNEMutation { done in
          manager.saveToPreferences { error in
            defer { done() }
            if let error {
              self?.diag("onDemand cleared failed: \(error.localizedDescription)")
            } else {
              self?.diag("onDemand cleared: enabled=false rules=0")
            }
            DispatchQueue.main.async { completion?(error) }
          }
        }
      }
    }
  }

  func mapStatus(_ status: NEVPNStatus) -> (state: String, message: String) {
    switch status {
    case .disconnected:
      return ("disconnected", "")
    case .connecting, .reasserting:
      return ("connecting", "")
    case .connected:
      return ("connected", "")
    case .disconnecting:
      return ("disconnecting", "")
    case .invalid:
      return ("error", "VPN configuration invalid.")
    @unknown default:
      return ("error", "Unknown VPN status.")
    }
  }

  static func statusLabel(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
      return "invalid"
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .reasserting:
      return "reasserting"
    case .disconnecting:
      return "disconnecting"
    @unknown default:
      return "unknown"
    }
  }
}
