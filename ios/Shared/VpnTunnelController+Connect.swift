import Foundation
import NetworkExtension

extension VpnTunnelController {
  func connectWithStoredPayload(
    triggerSource: String = "controlIntent",
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let generation = beginConnectOperation() else {
      diag("connectWithStoredPayload rejected: already in flight")
      completion(.failure(VpnTunnelError.connectInProgress))
      return
    }
    let finish: (Result<Void, Error>) -> Void = { [weak self] result in
      guard self?.completeConnectOperation(generation) == true else { return }
      completion(result)
    }
    setConnectCancellation(generation) {
      completion(.failure(CancellationError()))
    }
    loadTunnelManager { result in
      switch result {
      case let .failure(error):
        finish(.failure(error))
      case let .success(manager):
        guard let manager else {
          finish(.failure(VpnTunnelError.missingPayload))
          return
        }
        guard let payload = try? VpnSharedStore.loadConnectPayload() else {
          self.diag("connectWithStoredPayload rejected: no connect payload (signed out?)")
          finish(.failure(VpnTunnelError.missingPayload))
          return
        }
        if let host = payload.uplinkHost, !host.isEmpty {
          self.diag("reconnect payload loaded with uplinkHost=\(host)")
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
            finish(.failure(error))
          case let .success(preparedManager):
            self.startExistingManagerTunnel(
              manager: preparedManager,
              payload: payload,
              sessionId: sessionId,
              connectTriggerSource: triggerSource,
              operationGeneration: generation,
              completion: finish
            )
          }
        }
      }
    }
  }

  func connect(
    configJson: String,
    uplinkHost: String?,
    uplinkIPv4s: [String] = [],
    vpnSessionId: String?,
    connectTriggerSource: String,
    refreshAssetsFromBundle: Bool,
    savePayload: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let generation = beginConnectOperation() else {
      diag("connect rejected: already in flight")
      completion(.failure(VpnTunnelError.connectInProgress))
      return
    }
    let finish: (Result<Void, Error>) -> Void = { [weak self] result in
      guard self?.completeConnectOperation(generation) == true else { return }
      completion(result)
    }
    setConnectCancellation(generation) {
      completion(.failure(CancellationError()))
    }

    runtimePrepQueue.async { [weak self] in
      guard let self else { return }
      guard self.isCurrentConnectOperation(generation) else { return }
      do {
        if savePayload {
          try VpnSharedStore.saveConnectPayload(configJson: configJson, uplinkHost: uplinkHost)
        }
        try self.writeSharedRuntimeFiles(configJson: configJson, refreshAssetsFromBundle: refreshAssetsFromBundle)
        VpnSharedStore.clearExtensionHeartbeat()
        VpnSharedStore.clearTunnelStartFailure()
        VpnSharedStore.appendJournalLine(
          "[vpn] connect: writing config assetsRefresh=\(refreshAssetsFromBundle)"
        )
        Self.setControlState("connecting")
      } catch {
        Self.setControlState("error")
        finish(.failure(error))
        return
      }
      guard self.isCurrentConnectOperation(generation) else { return }

      let effectiveSessionId = Self.normalizedSessionId(vpnSessionId) ?? Self.newSessionId()
      if let cached = self.cachedManager, Self.canStartWithoutPersisting(cached) {
        #if os(macOS)
        if let mismatch = Self.embeddedAppexBundleMismatchDiag() {
          self.diag(mismatch)
          finish(.failure(VpnTunnelError.appexBundleMismatch))
          return
        }
        #endif
        self.startTunnelAfterPrep(
          manager: cached,
          uplinkHost: uplinkHost,
          uplinkIPv4s: uplinkIPv4s,
          sessionId: effectiveSessionId,
          connectTriggerSource: connectTriggerSource,
          persistPreferences: false,
          operationGeneration: generation,
          completion: finish
        )
        return
      }

      self.loadTunnelManager { [weak self] result in
        guard let self else { return }
        guard self.isCurrentConnectOperation(generation) else { return }
        switch result {
        case let .failure(error):
          Self.setControlState("error")
          finish(.failure(error))
        case let .success(existing):
          #if os(macOS)
          if let mismatch = Self.embeddedAppexBundleMismatchDiag() {
            self.diag(mismatch)
            finish(.failure(VpnTunnelError.appexBundleMismatch))
            return
          }
          #endif
          let manager = existing ?? NETunnelProviderManager()
          let persist = !(existing.map(Self.canStartWithoutPersisting) ?? false)
          self.startTunnelAfterPrep(
            manager: manager,
            uplinkHost: uplinkHost,
            uplinkIPv4s: uplinkIPv4s,
            sessionId: effectiveSessionId,
            connectTriggerSource: connectTriggerSource,
            persistPreferences: persist,
            operationGeneration: generation,
            completion: finish
          )
        }
      }
    }
  }

  /// Starts tunnel; persists NE preferences only when the Demar profile is missing/disabled/mismatched.
  func startTunnelAfterPrep(
    manager: NETunnelProviderManager,
    uplinkHost: String?,
    uplinkIPv4s: [String],
    sessionId: String,
    connectTriggerSource: String,
    persistPreferences: Bool,
    operationGeneration: UInt64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let opts = Self.makeStartOptions(
      uplinkHost: uplinkHost,
      uplinkIPv4s: uplinkIPv4s,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    VpnSharedStore.saveActiveSession(sessionId: sessionId, triggerSource: connectTriggerSource)

    guard persistPreferences else {
      diag("connect NE fast-path skipPrefsSave")
      VpnSharedStore.appendJournalLine("[vpn] connect: NE fast-path")
      cachedManager = manager
      startTunnelWithConflictRecovery(
        manager: manager,
        options: opts,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource,
        operationGeneration: operationGeneration,
        completion: completion
      )
      return
    }

    diag("connect NE full-path savePrefs")
    VpnSharedStore.appendJournalLine("[vpn] connect: NE full-path")
    Self.applyTunnelProtocol(
      to: manager,
      uplinkHost: uplinkHost,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    manager.localizedDescription = "Demar Proxy"
    manager.isEnabled = true
    manager.onDemandRules = nil
    manager.isOnDemandEnabled = false

    performNEMutation { [weak self] done in
      guard let self else {
        done()
        return
      }
      manager.saveToPreferences { error in
        if let error {
          done()
          Self.setControlState("error")
          #if os(macOS)
          self.diag("saveToPreferences failed: \(error.localizedDescription)")
          #endif
          completion(.failure(error))
          return
        }
        manager.loadFromPreferences { error in
          defer { done() }
          if let error {
            Self.setControlState("error")
            completion(.failure(error))
            return
          }
          guard self.isCurrentConnectOperation(operationGeneration) else { return }
          self.cachedManager = manager
          #if os(macOS)
          self.diagNeSnapshot(manager, label: "preferences loaded")
          #endif
          self.startTunnelWithConflictRecovery(
            manager: manager,
            options: opts,
            sessionId: sessionId,
            connectTriggerSource: connectTriggerSource,
            operationGeneration: operationGeneration,
            completion: completion
          )
        }
      }
    }
  }

  /// Enabled Demar profile already in preferences — ephemeral fields go via `startTunnel(options:)`.
  static func canStartWithoutPersisting(_ manager: NETunnelProviderManager) -> Bool {
    manager.isEnabled && isDemarManager(manager)
  }

  static func makeStartOptions(
    uplinkHost: String?,
    uplinkIPv4s: [String],
    sessionId: String,
    connectTriggerSource: String
  ) -> [String: NSObject] {
    var opts: [String: NSObject] = [
      VpnTunnelProviderKeys.uplinkHost: (uplinkHost ?? "") as NSObject,
      VpnTunnelProviderKeys.sessionId: sessionId as NSObject,
      VpnTunnelProviderKeys.connectSource: connectTriggerSource as NSObject,
    ]
    let ips = uplinkIPv4s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if !ips.isEmpty {
      opts[VpnTunnelProviderKeys.uplinkIPv4s] = ips.joined(separator: ",") as NSObject
    }
    return opts
  }
  func writeSharedRuntimeFiles(configJson: String, refreshAssetsFromBundle: Bool) throws {
    _ = try VpnSharedStore.vpnDirectoryURL()
    let cfgURL = try VpnAppGroup.configURL()
    let merged = try Self.configJsonWithCoreLogFile(configJson)
    try merged.data(using: .utf8)?.write(to: cfgURL, options: [.atomic])
    let assetDir = try VpnAppGroup.assetDirectoryURL()
    try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
    if refreshAssetsFromBundle {
      try CoreBundleAssets.copyGeoIfPresent(to: assetDir)
    }
    _ = CoreBundleAssets.ensureAds(in: assetDir)
    if !CoreBundleAssets.hasGeo(in: assetDir) {
      throw VpnTunnelError.missingAssets
    }
    #if os(macOS)
    Self.logConnectPreflight(cfgURL: cfgURL, assetDir: assetDir)
    #endif
  }


  func startExistingManagerTunnel(
    manager: NETunnelProviderManager,
    payload: VpnConnectPayload?,
    sessionId: String,
    connectTriggerSource: String,
    operationGeneration: UInt64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    runtimePrepQueue.async { [weak self] in
      guard let self else { return }
      guard self.isCurrentConnectOperation(operationGeneration) else { return }
      let resolvedPayload: VpnConnectPayload?
      do {
        if let payload {
          try self.writeSharedRuntimeFiles(configJson: payload.configJson, refreshAssetsFromBundle: false)
          resolvedPayload = payload
        } else if let cfg = try Self.readExistingSharedConfigJson() {
          try self.writeSharedRuntimeFiles(configJson: cfg, refreshAssetsFromBundle: false)
          resolvedPayload = nil
        } else {
          completion(.failure(VpnTunnelError.missingPayload))
          return
        }
      } catch {
        completion(.failure(error))
        return
      }
      guard self.isCurrentConnectOperation(operationGeneration) else { return }

      let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
      let payloadHost = resolvedPayload?.uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines)
      let payloadHostFromConfig = resolvedPayload.flatMap { payload in
        Self.extractUplinkHost(fromConfigJson: payload.configJson)
      }
      let providerHost = (proto?.providerConfiguration?[VpnTunnelProviderKeys.uplinkHost] as? String)?
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
        self.diag("reconnect aborted: missing uplinkHost in payload and provider configuration")
        completion(.failure(VpnTunnelError.missingUplinkHost))
        return
      }
      self.diag("reconnect using uplinkHost=\(uplinkHost)")
      let opts = Self.makeStartOptions(
        uplinkHost: uplinkHost,
        uplinkIPv4s: [],
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource
      )
      VpnSharedStore.saveActiveSession(sessionId: sessionId, triggerSource: connectTriggerSource)

      self.startTunnelWithConflictRecovery(
        manager: manager,
        options: opts,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource,
        operationGeneration: operationGeneration,
        completion: completion
      )
    }
  }

  func prepareManagerForConnect(
    _ manager: NETunnelProviderManager,
    payload: VpnConnectPayload?,
    sessionId: String,
    connectTriggerSource: String,
    completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void
  ) {
    manager.onDemandRules = nil
    manager.isOnDemandEnabled = false
    let payloadHost = payload?.uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines)
    let uplink = (payloadHost?.isEmpty == false) ? payloadHost : nil

    if Self.canStartWithoutPersisting(manager) {
      diag("reconnect NE fast-path skipPrefsSave")
      VpnSharedStore.appendJournalLine("[vpn] reconnect: NE fast-path")
      cachedManager = manager
      DispatchQueue.main.async { completion(.success(manager)) }
      return
    }

    diag("reconnect NE full-path savePrefs")
    VpnSharedStore.appendJournalLine("[vpn] reconnect: NE full-path")
    manager.isEnabled = true
    Self.applyTunnelProtocol(
      to: manager,
      uplinkHost: uplink,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    performNEMutation { done in
      manager.saveToPreferences { error in
        if let error {
          done()
          DispatchQueue.main.async { completion(.failure(error)) }
          return
        }
        manager.loadFromPreferences { error in
          defer { done() }
          DispatchQueue.main.async {
            if let error {
              completion(.failure(error))
            } else {
              self.cachedManager = manager
              completion(.success(manager))
            }
          }
        }
      }
    }
  }

  func startTunnelWithConflictRecovery(
    manager: NETunnelProviderManager,
    options: [String: NSObject],
    sessionId: String,
    connectTriggerSource: String,
    operationGeneration: UInt64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard isCurrentConnectOperation(operationGeneration) else { return }
    diag("startTunnel session=\(sessionId) source=\(connectTriggerSource)")
    guard manager.isEnabled else {
      diag("startTunnel blocked: VPN profile disabled (isEnabled=false)")
      Self.setControlState("error")
      completion(.failure(VpnTunnelError.managerDisabled))
      return
    }
    #if os(macOS)
    diagNeSnapshot(manager, label: "pre-startTunnel")
    #endif
    guard let session = manager.connection as? NETunnelProviderSession else {
      let kind = String(describing: type(of: manager.connection))
      diag("startTunnel failed: connection type=\(kind), expected NETunnelProviderSession")
      Self.setControlState("error")
      completion(.failure(VpnTunnelError.noProviderSession))
      return
    }
    do {
      diag("startTunnel call status=\(Self.statusLabel(manager.connection.status))")
      try session.startTunnel(options: options)
      diag("startTunnel returned ok status=\(Self.statusLabel(manager.connection.status))")
      #if os(macOS)
      scheduleMacOSPostStartProbes(
        manager: manager,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource
      )
      #endif
      Self.setControlState("connecting")
      waitForTunnelReadiness(
        manager: manager,
        deadline: Date().addingTimeInterval(70),
        operationGeneration: operationGeneration,
        completion: completion
      )
      return
    } catch {
      // NE preference propagation can lag; retry a few times after stopping our stale session.
      diag("startTunnel failed, retrying: \(error.localizedDescription)")
      retryStartTunnel(
        manager: manager,
        options: options,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource,
        attemptsRemaining: 2,
        operationGeneration: operationGeneration,
        completion: completion
      )
    }
  }

  func retryStartTunnel(
    manager: NETunnelProviderManager,
    options: [String: NSObject],
    sessionId: String,
    connectTriggerSource: String,
    attemptsRemaining: Int,
    operationGeneration: UInt64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard isCurrentConnectOperation(operationGeneration) else { return }
    let status = manager.connection.status
    if Self.shouldStopBeforeRetry(status) {
      VpnSharedStore.setPendingStopContext(triggerSource: "recovery", sessionId: sessionId)
      manager.connection.stopVPNTunnel()
      diag("recovery requested stop for status=\(Self.statusLabel(status))")
    } else {
      diag("recovery skip stop for status=\(Self.statusLabel(status))")
    }
    performNEMutation { [weak self] done in
      guard let self else {
        done()
        return
      }
      manager.loadFromPreferences { loadError in
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          guard self.isCurrentConnectOperation(operationGeneration) else { return }
          if let loadError {
            Self.setControlState("error")
            completion(.failure(loadError))
            return
          }
          do {
            self.syncManagerConnectionMetadata(
              manager,
              uplinkHost: nil,
              sessionId: sessionId,
              connectTriggerSource: connectTriggerSource
            )
            guard let refreshedSession = manager.connection as? NETunnelProviderSession else {
              self.diag("startTunnel retry failed: no NETunnelProviderSession")
              Self.setControlState("error")
              completion(.failure(VpnTunnelError.noProviderSession))
              return
            }
            try refreshedSession.startTunnel(options: options)
            self.diag("startTunnel retry succeeded (attemptsLeft=\(attemptsRemaining))")
            Self.setControlState("connecting")
            self.waitForTunnelReadiness(
              manager: manager,
              deadline: Date().addingTimeInterval(70),
              operationGeneration: operationGeneration,
              completion: completion
            )
          } catch {
            guard attemptsRemaining > 1 else {
              self.diag("startTunnel retry failed: \(error.localizedDescription)")
              Self.setControlState("error")
              completion(.failure(error))
              return
            }
            self.diag("startTunnel retry failed, retrying again: \(error.localizedDescription)")
            self.retryStartTunnel(
              manager: manager,
              options: options,
              sessionId: sessionId,
              connectTriggerSource: connectTriggerSource,
              attemptsRemaining: attemptsRemaining - 1,
              operationGeneration: operationGeneration,
              completion: completion
            )
          }
        }
      }
    }
  }
  static func readExistingSharedConfigJson() throws -> String? {
    let cfgURL = try VpnAppGroup.configURL()
    guard FileManager.default.fileExists(atPath: cfgURL.path) else { return nil }
    let raw = try String(contentsOf: cfgURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
  }

  static func configJsonWithCoreLogFile(_ configJson: String) throws -> String {
    let output = try VpnAppGroup.coreLogFileURL()
    guard let data = configJson.data(using: .utf8),
      let rootRaw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return configJson }
    var root = rootRaw
    var logObj = (root["log"] as? [String: Any]) ?? [:]
    // Force info so reconnect / stale warning configs still log every dial (Telegram DC).
    logObj["level"] = "info"
    logObj["timestamp"] = true
    logObj["output"] = output.path
    root["log"] = logObj
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    return String(data: out, encoding: .utf8) ?? configJson
  }

  static func extractUplinkHost(fromConfigJson configJson: String) -> String? {
    guard let data = configJson.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let outbounds = root["outbounds"] as? [[String: Any]]
    else { return nil }
    for outbound in outbounds {
      guard (outbound["tag"] as? String) == "proxy" else { continue }
      let server = (outbound["server"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let server, !server.isEmpty { return server }
    }
    return nil
  }

  /// Applies packet-tunnel protocol fields shared by full connect and Control Center reconnect.
  static func applyTunnelProtocol(
    to manager: NETunnelProviderManager,
    uplinkHost: String?,
    sessionId: String?,
    connectTriggerSource: String?
  ) {
    let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    proto.providerBundleIdentifier = packetTunnelBundleId
    proto.serverAddress = Self.normalizedServerAddress(uplinkHost)
    proto.disconnectOnSleep = false
    // excludeAPNs/Cellular/Local require includeAllNetworks=true (Apple NE) — unused on purpose.
    proto.includeAllNetworks = false
    proto.enforceRoutes = false
    proto.providerConfiguration = mergedProviderConfiguration(
      current: proto.providerConfiguration,
      uplinkHost: uplinkHost,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    manager.protocolConfiguration = proto
  }

  func syncManagerConnectionMetadata(
    _ manager: NETunnelProviderManager,
    uplinkHost: String?,
    sessionId: String?,
    connectTriggerSource: String?
  ) {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return }
    proto.providerConfiguration = Self.mergedProviderConfiguration(
      current: proto.providerConfiguration,
      uplinkHost: uplinkHost,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    manager.protocolConfiguration = proto
  }

  func extractSessionId(from manager: NETunnelProviderManager) -> String? {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
    return Self.normalizedSessionId(proto.providerConfiguration?[VpnTunnelProviderKeys.sessionId] as? String)
  }

  static func mergedProviderConfiguration(
    current: [String: Any]?,
    uplinkHost: String?,
    sessionId: String?,
    connectTriggerSource: String?
  ) -> [String: Any] {
    var providerCfg = current ?? [:]
    if let uplinkHost, !uplinkHost.isEmpty {
      providerCfg[VpnTunnelProviderKeys.uplinkHost] = uplinkHost as NSObject
    }
    if let sessionId = normalizedSessionId(sessionId) {
      providerCfg[VpnTunnelProviderKeys.sessionId] = sessionId as NSObject
    }
    if let connectTriggerSource,
      !connectTriggerSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      providerCfg[VpnTunnelProviderKeys.connectSource] = connectTriggerSource as NSObject
    }
    return providerCfg
  }

  static func normalizedSessionId(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  static func newSessionId() -> String {
    UUID().uuidString.lowercased()
  }

  static func shouldStopBeforeRetry(_ status: NEVPNStatus) -> Bool {
    switch status {
    case .connected, .connecting, .reasserting, .disconnecting:
      return true
    case .disconnected, .invalid:
      return false
    @unknown default:
      return true
    }
  }

  static func normalizedServerAddress(_ uplinkHost: String?) -> String {
    let host = uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return host.isEmpty ? "Demar Proxy" : host
  }
}
