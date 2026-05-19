import Foundation
import NetworkExtension
#if canImport(WidgetKit)
import WidgetKit
#endif

enum VpnTunnelError: LocalizedError {
  case missingPayload
  case missingAssets
  case missingUplinkHost

  var errorDescription: String? {
    switch self {
    case .missingPayload:
      return "Откройте приложение Demar VPN один раз для первичной инициализации."
    case .missingAssets:
      return "Для запуска VPN из Control Center сначала откройте приложение Demar VPN."
    case .missingUplinkHost:
      return "Не удалось определить uplinkHost для исключения маршрута VPN."
    }
  }
}

final class VpnTunnelController {
  static let shared = VpnTunnelController()
  static let packetTunnelBundleId = "com.demar.vpn.packet-tunnel"
  private static let providerKeyUplinkHost = "uplinkHost"
  private static let providerKeySessionId = "vpnSessionId"
  private static let providerKeyConnectSource = "connectTriggerSource"

  private init() {}

  private func diag(_ message: String) {
    VpnSharedStore.appendPendingUiDiagLine("[ios] \(message)")
  }

  func loadTunnelManager(completion: @escaping (Result<NETunnelProviderManager?, Error>) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(error))
          return
        }
        let match = managers?.first(where: { manager in
          guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            return false
          }
          return proto.providerBundleIdentifier == Self.packetTunnelBundleId
        })
        completion(.success(match))
      }
    }
  }

  func currentStatus(completion: @escaping (NEVPNStatus) -> Void) {
    loadTunnelManager { result in
      switch result {
      case let .success(manager):
        completion(manager?.connection.status ?? .disconnected)
      case .failure:
        completion(.disconnected)
      }
    }
  }

  func connectWithStoredPayload(
    triggerSource: String = "controlIntent",
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    loadTunnelManager { result in
      switch result {
      case let .failure(error):
        completion(.failure(error))
      case let .success(manager):
        guard let manager else {
          completion(.failure(VpnTunnelError.missingPayload))
          return
        }
        let payload = (try? VpnSharedStore.loadConnectPayload()) ?? nil
        if payload?.uplinkHost?.isEmpty == false {
          self.diag("reconnect payload loaded with uplinkHost=\(payload?.uplinkHost ?? "<none>")")
        } else {
          self.diag("reconnect payload loaded without uplinkHost")
        }
        let sessionId = Self.newSessionId()
        self.prepareManagerForConnect(
          manager,
          payload: payload,
          sessionId: sessionId,
          connectTriggerSource: triggerSource
        ) { prepareResult in
          switch prepareResult {
          case let .failure(error):
            completion(.failure(error))
          case let .success(preparedManager):
            self.startExistingManagerTunnel(
              manager: preparedManager,
              payload: payload,
              sessionId: sessionId,
              connectTriggerSource: triggerSource,
              completion: completion
            )
          }
        }
      }
    }
  }

  func connect(
    configJson: String,
    uplinkHost: String?,
    vpnSessionId: String?,
    connectTriggerSource: String,
    refreshAssetsFromBundle: Bool,
    savePayload: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      if savePayload {
        try VpnSharedStore.saveConnectPayload(configJson: configJson, uplinkHost: uplinkHost)
      }
      try writeSharedRuntimeFiles(configJson: configJson, refreshAssetsFromBundle: refreshAssetsFromBundle)
      VpnSharedStore.saveControlState("connecting")
      Self.reloadControls()
    } catch {
      VpnSharedStore.saveControlState("error")
      Self.reloadControls()
      completion(.failure(error))
      return
    }

    loadTunnelManager { [weak self] result in
      guard let self else { return }
      switch result {
      case let .failure(error):
        VpnSharedStore.saveControlState("error")
        Self.reloadControls()
        completion(.failure(error))
      case let .success(existing):
        let manager = existing ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.packetTunnelBundleId
        proto.serverAddress = "Demar VPN"
        proto.disconnectOnSleep = false
        var providerCfg: [String: NSObject] = [:]
        if let uplinkHost, !uplinkHost.isEmpty {
          providerCfg[Self.providerKeyUplinkHost] = uplinkHost as NSObject
        }
        let effectiveSessionId = Self.normalizedSessionId(vpnSessionId) ?? Self.newSessionId()
        providerCfg[Self.providerKeySessionId] = effectiveSessionId as NSObject
        providerCfg[Self.providerKeyConnectSource] = connectTriggerSource as NSObject
        proto.providerConfiguration = providerCfg

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Demar VPN"
        manager.isEnabled = true
        // Do not use NEOnDemandRuleConnect / on-demand "always connect": if the user turns VPN off in
        // Settings, iOS would immediately reconnect and our Control toggle could not stay off.
        manager.onDemandRules = nil
        manager.isOnDemandEnabled = false

        manager.saveToPreferences { error in
          if let error {
            VpnSharedStore.saveControlState("error")
            Self.reloadControls()
            DispatchQueue.main.async { completion(.failure(error)) }
            return
          }
          manager.loadFromPreferences { error in
            if let error {
              VpnSharedStore.saveControlState("error")
              Self.reloadControls()
              DispatchQueue.main.async { completion(.failure(error)) }
              return
            }

            let session = manager.connection as? NETunnelProviderSession
            let opts: [String: NSObject] = [
              Self.providerKeyUplinkHost: (uplinkHost ?? "") as NSObject,
              Self.providerKeySessionId: effectiveSessionId as NSObject,
              Self.providerKeyConnectSource: connectTriggerSource as NSObject,
            ]
            VpnSharedStore.saveActiveSession(
              sessionId: effectiveSessionId,
              triggerSource: connectTriggerSource
            )

            do {
              try session?.startTunnel(options: opts)
              DispatchQueue.main.async {
                completion(.success(()))
              }
            } catch {
              VpnSharedStore.saveControlState("error")
              Self.reloadControls()
              DispatchQueue.main.async {
                completion(.failure(error))
              }
            }
          }
        }
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
    VpnSharedStore.saveControlState("disconnecting")
    Self.reloadControls()
    loadTunnelManager { result in
      switch result {
      case let .failure(error):
        VpnSharedStore.saveControlState("error")
        Self.reloadControls()
        completion(.failure(error))
      case let .success(manager):
        guard let manager else {
          VpnSharedStore.saveControlState("disconnected")
          Self.reloadControls()
          completion(.success(()))
          return
        }

        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        manager.saveToPreferences { error in
          DispatchQueue.main.async {
            if let error {
              VpnSharedStore.saveControlState("error")
              Self.reloadControls()
              completion(.failure(error))
              return
            }
            let sessionId = self.extractSessionId(from: manager) ?? VpnSharedStore.loadActiveSession()?["sessionId"]
            VpnSharedStore.setPendingStopContext(triggerSource: triggerSource, sessionId: sessionId)
            manager.connection.stopVPNTunnel()
            VpnSharedStore.saveControlState("disconnected")
            Self.reloadControls()
            completion(.success(()))
          }
        }
      }
    }
  }

  /// Clears on-demand VPN rules saved in preferences so disconnecting from Settings does not auto-reconnect.
  func disableOnDemandAutoReconnect(completion: ((Error?) -> Void)? = nil) {
    loadTunnelManager { result in
      switch result {
      case let .failure(error):
        DispatchQueue.main.async { completion?(error) }
      case let .success(manager):
        guard let manager else {
          DispatchQueue.main.async { completion?(nil) }
          return
        }
        let hadOnDemand = manager.isOnDemandEnabled || !(manager.onDemandRules?.isEmpty ?? true)
        guard hadOnDemand else {
          DispatchQueue.main.async { completion?(nil) }
          return
        }
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        manager.saveToPreferences { error in
          DispatchQueue.main.async { completion?(error) }
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

  private func writeSharedRuntimeFiles(configJson: String, refreshAssetsFromBundle: Bool) throws {
    _ = try VpnSharedStore.vpnDirectoryURL()
    let cfgURL = try VpnAppGroup.configURL()
    let merged = try Self.configJsonWithXrayLogFiles(configJson)
    try merged.data(using: .utf8)?.write(to: cfgURL, options: [.atomic])
    let assetDir = try VpnAppGroup.assetDirectoryURL()
    try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
    if refreshAssetsFromBundle {
      try Self.copyBundledGeoIfPresent(to: assetDir)
    } else if !Self.hasRequiredAssets(in: assetDir) {
      throw VpnTunnelError.missingAssets
    }
  }

  private func startExistingManagerTunnel(
    manager: NETunnelProviderManager,
    payload: VpnConnectPayload?,
    sessionId: String,
    connectTriggerSource: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let resolvedPayload: VpnConnectPayload?
    do {
      if let payload {
        try writeSharedRuntimeFiles(configJson: payload.configJson, refreshAssetsFromBundle: false)
        resolvedPayload = payload
      } else if let cfg = try Self.readExistingSharedConfigJson() {
        try writeSharedRuntimeFiles(configJson: cfg, refreshAssetsFromBundle: false)
        resolvedPayload = nil
      } else {
        completion(.failure(VpnTunnelError.missingPayload))
        return
      }
    } catch {
      completion(.failure(error))
      return
    }

    let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
    let payloadHost = resolvedPayload?.uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines)
    let payloadHostFromConfig = resolvedPayload.flatMap { payload in
      Self.extractUplinkHost(fromConfigJson: payload.configJson)
    }
    let providerHost = (proto?.providerConfiguration?["uplinkHost"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let uplinkHost: String?
    if let payloadHost, !payloadHost.isEmpty {
      uplinkHost = payloadHost
    } else if let payloadHostFromConfig, !payloadHostFromConfig.isEmpty {
      uplinkHost = payloadHostFromConfig
    } else if let providerHost, !providerHost.isEmpty {
      uplinkHost = providerHost
    } else {
      uplinkHost = nil
    }
    guard let uplinkHost else {
      diag("reconnect aborted: missing uplinkHost in payload and provider configuration")
      completion(.failure(VpnTunnelError.missingUplinkHost))
      return
    }
    diag("reconnect using uplinkHost=\(uplinkHost)")
    syncManagerConnectionMetadata(
      manager,
      uplinkHost: uplinkHost,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    let opts: [String: NSObject] = [
      Self.providerKeyUplinkHost: uplinkHost as NSObject,
      Self.providerKeySessionId: sessionId as NSObject,
      Self.providerKeyConnectSource: connectTriggerSource as NSObject,
    ]
    VpnSharedStore.saveActiveSession(sessionId: sessionId, triggerSource: connectTriggerSource)

    startTunnelWithConflictRecovery(
      manager: manager,
      options: opts,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource,
      completion: completion
    )
  }

  private func prepareManagerForConnect(
    _ manager: NETunnelProviderManager,
    payload: VpnConnectPayload?,
    sessionId: String,
    connectTriggerSource: String,
    completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void
  ) {
    manager.isEnabled = true
    manager.onDemandRules = nil
    manager.isOnDemandEnabled = false
    if let payloadHost = payload?.uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines),
      !payloadHost.isEmpty
    {
      syncManagerConnectionMetadata(
        manager,
        uplinkHost: payloadHost,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource
      )
    } else {
      syncManagerConnectionMetadata(
        manager,
        uplinkHost: nil,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource
      )
    }
    manager.saveToPreferences { error in
      if let error {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      manager.loadFromPreferences { error in
        DispatchQueue.main.async {
          if let error {
            completion(.failure(error))
          } else {
            completion(.success(manager))
          }
        }
      }
    }
  }

  private func startTunnelWithConflictRecovery(
    manager: NETunnelProviderManager,
    options: [String: NSObject],
    sessionId: String,
    connectTriggerSource: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let session = manager.connection as? NETunnelProviderSession
    do {
      try session?.startTunnel(options: options)
      VpnSharedStore.saveControlState("connecting")
      Self.reloadControls()
      completion(.success(()))
      return
    } catch {
      // Retry once after stopping our own stale session and reloading preferences.
      diag("startTunnel failed, retrying once: \(error.localizedDescription)")
      let status = manager.connection.status
      let shouldStop = Self.shouldStopBeforeRetry(status)
      if shouldStop {
        VpnSharedStore.setPendingStopContext(triggerSource: "recovery", sessionId: sessionId)
        manager.connection.stopVPNTunnel()
        diag("recovery requested stop for status=\(Self.statusLabel(status))")
      } else {
        diag("recovery skip stop for status=\(Self.statusLabel(status))")
      }
      manager.loadFromPreferences { loadError in
        let delay: TimeInterval = shouldStop ? 0.6 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          if let loadError {
            VpnSharedStore.saveControlState("error")
            Self.reloadControls()
            completion(.failure(loadError))
            return
          }
          do {
            let refreshedSession = manager.connection as? NETunnelProviderSession
            self.syncManagerConnectionMetadata(
              manager,
              uplinkHost: nil,
              sessionId: sessionId,
              connectTriggerSource: connectTriggerSource
            )
            try refreshedSession?.startTunnel(options: options)
            self.diag("startTunnel retry succeeded")
            VpnSharedStore.saveControlState("connecting")
            Self.reloadControls()
            completion(.success(()))
          } catch {
            self.diag("startTunnel retry failed: \(error.localizedDescription)")
            VpnSharedStore.saveControlState("error")
            Self.reloadControls()
            completion(.failure(error))
          }
        }
      }
    }
  }

  private static func readExistingSharedConfigJson() throws -> String? {
    let cfgURL = try VpnAppGroup.configURL()
    guard FileManager.default.fileExists(atPath: cfgURL.path) else { return nil }
    let raw = try String(contentsOf: cfgURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
  }

  private static func hasRequiredAssets(in assetDir: URL) -> Bool {
    let fm = FileManager.default
    let geoip = assetDir.appendingPathComponent("geoip.dat", isDirectory: false).path
    let geosite = assetDir.appendingPathComponent("geosite.dat", isDirectory: false).path
    return fm.fileExists(atPath: geoip) && fm.fileExists(atPath: geosite)
  }

  static func copyBundledGeoIfPresent(to destinationDir: URL) throws {
    let names = ["geoip.dat", "geosite.dat"]
    for name in names {
      let components = name.split(separator: ".")
      let base = String(components.first ?? "")
      let ext = components.count > 1 ? String(components.dropFirst().joined(separator: ".")) : ""
      let subs = ["Shared/xray", "xray"]
      var src: URL?
      for sub in subs {
        if let u = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: sub) {
          src = u
          break
        }
      }
      guard let src else { continue }
      let dst = destinationDir.appendingPathComponent(name, isDirectory: false)
      if FileManager.default.fileExists(atPath: dst.path) {
        try FileManager.default.removeItem(at: dst)
      }
      try FileManager.default.copyItem(at: src, to: dst)
    }
  }

  private static func reloadControls() {
#if canImport(WidgetKit)
    if #available(iOS 18.0, *) {
      DispatchQueue.main.async {
        ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
      }
    }
#endif
  }

  private static func configJsonWithXrayLogFiles(_ configJson: String) throws -> String {
    let err = try VpnAppGroup.xrayErrorLogFileURL()
    let acc = try VpnAppGroup.xrayAccessLogFileURL()
    guard let data = configJson.data(using: .utf8),
      let rootRaw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return configJson }
    var root = rootRaw
    var logObj = (root["log"] as? [String: Any]) ?? [:]
    if logObj["loglevel"] == nil { logObj["loglevel"] = "info" }
    logObj["error"] = err.path
    logObj["access"] = acc.path
    root["log"] = logObj
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    return String(data: out, encoding: .utf8) ?? configJson
  }

  private static func extractUplinkHost(fromConfigJson configJson: String) -> String? {
    guard let data = configJson.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let outbounds = root["outbounds"] as? [[String: Any]]
    else { return nil }
    for outbound in outbounds {
      guard (outbound["protocol"] as? String) == "vless" else { continue }
      guard let settings = outbound["settings"] as? [String: Any],
        let vnext = settings["vnext"] as? [[String: Any]]
      else { continue }
      for endpoint in vnext {
        let address = (endpoint["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address, !address.isEmpty {
          return address
        }
      }
    }
    return nil
  }

  private func syncManagerUplinkHost(_ manager: NETunnelProviderManager, uplinkHost: String) {
    syncManagerConnectionMetadata(
      manager,
      uplinkHost: uplinkHost,
      sessionId: nil,
      connectTriggerSource: nil
    )
  }

  private func syncManagerConnectionMetadata(
    _ manager: NETunnelProviderManager,
    uplinkHost: String?,
    sessionId: String?,
    connectTriggerSource: String?
  ) {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return }
    var providerCfg = proto.providerConfiguration ?? [:]
    if let uplinkHost, !uplinkHost.isEmpty {
      providerCfg[Self.providerKeyUplinkHost] = uplinkHost as NSObject
    }
    if let sessionId = Self.normalizedSessionId(sessionId) {
      providerCfg[Self.providerKeySessionId] = sessionId as NSObject
    }
    if let connectTriggerSource,
      !connectTriggerSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      providerCfg[Self.providerKeyConnectSource] = connectTriggerSource as NSObject
    }
    proto.providerConfiguration = providerCfg
    manager.protocolConfiguration = proto
  }

  private func extractSessionId(from manager: NETunnelProviderManager) -> String? {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
    return Self.normalizedSessionId(proto.providerConfiguration?[Self.providerKeySessionId] as? String)
  }

  private static func normalizedSessionId(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func newSessionId() -> String {
    UUID().uuidString.lowercased()
  }

  private static func shouldStopBeforeRetry(_ status: NEVPNStatus) -> Bool {
    switch status {
    case .connected, .connecting, .reasserting, .disconnecting:
      return true
    case .disconnected, .invalid:
      return false
    @unknown default:
      return true
    }
  }

  private static func statusLabel(_ status: NEVPNStatus) -> String {
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
