import Foundation
import NetworkExtension
import Darwin

enum VpnTunnelError: LocalizedError {
  case missingPayload
  case missingAssets
  case missingUplinkHost
  case managerDisabled
  case connectInProgress
  case noProviderSession
  case appexBundleMismatch

  var errorDescription: String? {
    switch self {
    case .missingPayload:
      return String(localized: "Open the Demar Proxy app once for initial setup.")
    case .missingAssets:
      return String(localized: "Core assets are missing. Run: python3 scripts/singbox-download-auto.py")
    case .missingUplinkHost:
      return String(localized: "Couldn’t resolve uplinkHost for the VPN route exclusion.")
    case .managerDisabled:
      return String(localized: "VPN profile is disabled in the system. Enable Demar Proxy in System Settings → VPN.")
    case .connectInProgress:
      return String(localized: "A connection is already in progress.")
    case .noProviderSession:
      return String(localized: "Couldn’t open a VPN session (NETunnelProviderSession). Reinstall the VPN profile in system settings.")
    case .appexBundleMismatch:
      return String(localized: "The embedded DemarPacketTunnel extension is damaged or missing. Reinstall the app.")
    }
  }
}

enum UplinkIPv4Resolver {
  static func resolve(_ host: String?) throws -> [String] {
    let clean = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !clean.isEmpty else { return [] }
    var literal = in_addr()
    if clean.withCString({ inet_pton(AF_INET, $0, &literal) }) == 1 { return [clean] }

    var hints = addrinfo(
      ai_flags: AI_DEFAULT,
      ai_family: AF_INET,
      ai_socktype: SOCK_STREAM,
      ai_protocol: 0,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(clean, nil, &hints, &result)
    guard code == 0 else {
      throw NSError(domain: "DemarVpn", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "DNS lookup failed for \(clean): \(String(cString: gai_strerror(code)))",
      ])
    }
    defer { if let result { freeaddrinfo(result) } }

    var addresses = Set<String>()
    var cursor = result
    while let info = cursor?.pointee {
      if info.ai_family == AF_INET,
         let socketAddress = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 })
      {
        var address = socketAddress.pointee.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
          addresses.insert(String(cString: buffer))
        }
      }
      cursor = info.ai_next
    }
    guard !addresses.isEmpty else {
      throw NSError(domain: "DemarVpn", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "DNS lookup returned no IPv4 for \(clean).",
      ])
    }
    return addresses.sorted()
  }
}

final class VpnTunnelController {
  static let shared = VpnTunnelController()
  static let packetTunnelBundleId = "com.demar.adblock.packet-tunnel"

  private var connectInFlight = false
  private var connectGeneration: UInt64 = 0
  private var connectCancellation: (() -> Void)?
  private var readinessWorkItem: DispatchWorkItem?
  private let connectStateLock = NSLock()
  private var cachedManager: NETunnelProviderManager?
  /// Serializes all NetworkExtension preference load/save/remove mutations.
  private let neMutationQueue = DispatchQueue(label: "com.demar.adblock.neMutation")
  private let runtimePrepQueue = DispatchQueue(label: "com.demar.adblock.runtimePrep", qos: .userInitiated)

  var isConnectInFlight: Bool {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    return connectInFlight
  }

  private init() {}

  /// Runs NE preference work one-at-a-time. `work` must invoke `done` exactly once.
  private func performNEMutation(_ work: @escaping (_ done: @escaping () -> Void) -> Void) {
    neMutationQueue.async {
      let finished = DispatchSemaphore(value: 0)
      work { finished.signal() }
      _ = finished.wait(timeout: .now() + 90)
    }
  }

  private static func isDemarManager(_ manager: NETunnelProviderManager) -> Bool {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
      return false
    }
    return proto.providerBundleIdentifier == packetTunnelBundleId
  }

  private func diag(_ message: String) {
    #if os(macOS)
    VpnSharedStore.appendPendingUiDiagLine("[mac] \(message)")
    #else
    VpnSharedStore.appendPendingUiDiagLine("[ios] \(message)")
    #endif
  }

  private func beginConnectOperation() -> UInt64? {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    if connectInFlight { return nil }
    connectGeneration &+= 1
    connectInFlight = true
    return connectGeneration
  }

  private func completeConnectOperation(_ generation: UInt64) -> Bool {
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

  private func setConnectCancellation(_ generation: UInt64, _ cancellation: @escaping () -> Void) {
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

  private func isCurrentConnectOperation(_ generation: UInt64) -> Bool {
    connectStateLock.lock()
    defer { connectStateLock.unlock() }
    return connectInFlight && connectGeneration == generation
  }

  private static func setControlState(_ state: String) {
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
    invalidateCachedManager()
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
    invalidateCachedManager()
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
        VpnSharedStore.appendJournalLine("[vpn] connect: writing config and assets")
        Self.setControlState("connecting")
      } catch {
        Self.setControlState("error")
        finish(.failure(error))
        return
      }
      guard self.isCurrentConnectOperation(generation) else { return }

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
          let effectiveSessionId = Self.normalizedSessionId(vpnSessionId) ?? Self.newSessionId()
          Self.applyTunnelProtocol(
            to: manager,
            uplinkHost: uplinkHost,
            sessionId: effectiveSessionId,
            connectTriggerSource: connectTriggerSource
          )
          manager.localizedDescription = "Demar Proxy"
          // Enable profile so iOS prefers Demar over another VPN app when the user connects from our UI.
          manager.isEnabled = true
          manager.onDemandRules = nil
          manager.isOnDemandEnabled = false

          self.performNEMutation { done in
            manager.saveToPreferences { error in
              if let error {
                done()
                Self.setControlState("error")
                #if os(macOS)
                self.diag("saveToPreferences failed: \(error.localizedDescription)")
                #endif
                finish(.failure(error))
                return
              }
              manager.loadFromPreferences { error in
                defer { done() }
                if let error {
                  Self.setControlState("error")
                  finish(.failure(error))
                  return
                }
                guard self.isCurrentConnectOperation(generation) else { return }
                self.cachedManager = manager
                #if os(macOS)
                self.diagNeSnapshot(manager, label: "preferences loaded")
                #endif

                let opts: [String: NSObject] = [
                  VpnTunnelProviderKeys.uplinkHost: (uplinkHost ?? "") as NSObject,
                  VpnTunnelProviderKeys.sessionId: effectiveSessionId as NSObject,
                  VpnTunnelProviderKeys.connectSource: connectTriggerSource as NSObject,
                ]
                VpnSharedStore.saveActiveSession(
                  sessionId: effectiveSessionId,
                  triggerSource: connectTriggerSource
                )

                self.startTunnelWithConflictRecovery(
                  manager: manager,
                  options: opts,
                  sessionId: effectiveSessionId,
                  connectTriggerSource: connectTriggerSource,
                  operationGeneration: generation,
                  completion: finish
                )
              }
            }
          }
        }
      }
    }
  }

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

  /// Stops and cold-starts sing-box / Libbox in the packet-tunnel extension (tunnel must be connected).
  func hardRestartCore(completion: @escaping (Result<Void, Error>) -> Void) {
    sendProviderCommand("hardRestartCore", completion: completion)
  }

  private func sendProviderCommand(_ command: String, completion: @escaping (Result<Void, Error>) -> Void) {
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

  private func writeSharedRuntimeFiles(configJson: String, refreshAssetsFromBundle: Bool) throws {
    _ = try VpnSharedStore.vpnDirectoryURL()
    let cfgURL = try VpnAppGroup.configURL()
    let merged = try Self.configJsonWithCoreLogFile(configJson)
    try merged.data(using: .utf8)?.write(to: cfgURL, options: [.atomic])
    let assetDir = try VpnAppGroup.assetDirectoryURL()
    try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
    if refreshAssetsFromBundle {
      try CoreBundleAssets.copyGeoIfPresent(to: assetDir)
    }
    if !CoreBundleAssets.hasGeo(in: assetDir) {
      throw VpnTunnelError.missingAssets
    }
    #if os(macOS)
    Self.logConnectPreflight(cfgURL: cfgURL, assetDir: assetDir)
    #endif
  }

  #if os(macOS)
  private static func logConnectPreflight(cfgURL: URL, assetDir: URL) {
    let fm = FileManager.default
    let cfgSize = (try? fm.attributesOfItem(atPath: cfgURL.path)[.size] as? Int64) ?? -1
    let geoip = assetDir.appendingPathComponent("geoip.db")
    let geosite = assetDir.appendingPathComponent("geosite.db")
    let geoipSize = fm.fileExists(atPath: geoip.path)
      ? ((try? fm.attributesOfItem(atPath: geoip.path)[.size] as? Int64) ?? -1) : -1
    let geositeSize = fm.fileExists(atPath: geosite.path)
      ? ((try? fm.attributesOfItem(atPath: geosite.path)[.size] as? Int64) ?? -1) : -1
    VpnSharedStore.appendPendingUiDiagLine(
      "[vpn] preflight: config=\(cfgSize)B geoip=\(geoipSize)B geosite=\(geositeSize)B"
    )
    let appexExe = Bundle.main.builtInPlugInsURL?
      .appendingPathComponent("DemarPacketTunnel.appex/Contents/MacOS/DemarPacketTunnel")
    let corePath = appexExe?.path ?? "<missing>"
    let coreOK = appexExe.map { fm.isExecutableFile(atPath: $0.path) } ?? false
    VpnSharedStore.appendPendingUiDiagLine(
      "[vpn] preflight: appex=\(coreOK ? "ok" : "missing") path=\(corePath)"
    )
  }
  #endif

  private func startExistingManagerTunnel(
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
      self.syncManagerConnectionMetadata(
        manager,
        uplinkHost: uplinkHost,
        sessionId: sessionId,
        connectTriggerSource: connectTriggerSource
      )
      let opts: [String: NSObject] = [
        VpnTunnelProviderKeys.uplinkHost: uplinkHost as NSObject,
        VpnTunnelProviderKeys.sessionId: sessionId as NSObject,
        VpnTunnelProviderKeys.connectSource: connectTriggerSource as NSObject,
      ]
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
    let payloadHost = payload?.uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines)
    let uplink = (payloadHost?.isEmpty == false) ? payloadHost : nil
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

  private func startTunnelWithConflictRecovery(
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

  private func retryStartTunnel(
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

  private func waitForTunnelReadiness(
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

  private static func readExistingSharedConfigJson() throws -> String? {
    let cfgURL = try VpnAppGroup.configURL()
    guard FileManager.default.fileExists(atPath: cfgURL.path) else { return nil }
    let raw = try String(contentsOf: cfgURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
  }

  private static func configJsonWithCoreLogFile(_ configJson: String) throws -> String {
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

  private static func extractUplinkHost(fromConfigJson configJson: String) -> String? {
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
  private static func applyTunnelProtocol(
    to manager: NETunnelProviderManager,
    uplinkHost: String?,
    sessionId: String?,
    connectTriggerSource: String?
  ) {
    let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    proto.providerBundleIdentifier = packetTunnelBundleId
    proto.serverAddress = Self.normalizedServerAddress(uplinkHost)
    proto.disconnectOnSleep = false
    proto.includeAllNetworks = false
    proto.excludeAPNs = true
    proto.excludeCellularServices = true
    proto.excludeLocalNetworks = false
    proto.enforceRoutes = false
    proto.providerConfiguration = mergedProviderConfiguration(
      current: proto.providerConfiguration,
      uplinkHost: uplinkHost,
      sessionId: sessionId,
      connectTriggerSource: connectTriggerSource
    )
    manager.protocolConfiguration = proto
  }

  private func syncManagerConnectionMetadata(
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

  private func extractSessionId(from manager: NETunnelProviderManager) -> String? {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
    return Self.normalizedSessionId(proto.providerConfiguration?[VpnTunnelProviderKeys.sessionId] as? String)
  }

  private static func mergedProviderConfiguration(
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

  private static func normalizedServerAddress(_ uplinkHost: String?) -> String {
    let host = uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return host.isEmpty ? "Demar Proxy" : host
  }

  #if os(macOS)
  private func scheduleMacOSPostStartProbes(
    manager: NETunnelProviderManager,
    sessionId: String,
    connectTriggerSource: String
  ) {
    let delays: [TimeInterval] = [1.0, 3.0, 8.0]
    for delay in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        let heartbeat = VpnSharedStore.extensionHeartbeatPhase() ?? "none"
        let control = VpnSharedStore.loadControlState() ?? "none"
        let ne = Self.statusLabel(manager.connection.status)
        let lastJournal = VpnSharedStore.recentJournalLines(1).last ?? "none"
        let startError = VpnSharedStore.readTunnelStartFailureSnapshot() ?? "none"
        self.diag(
          String(
            format: "post-start probe +%.1fs: ne=%@ heartbeat=%@ control=%@ session=%@ source=%@ startError=%@ lastJournal=%@",
            delay,
            ne,
            heartbeat,
            control,
            sessionId,
            connectTriggerSource,
            startError,
            lastJournal
          )
        )
        if heartbeat == "none", manager.connection.status == .disconnected {
          self.diag(
            "NE accepted start, but extension is not running; check Network Extensions toggle and recreate VPN profile"
          )
        }
      }
    }
  }

  private static func embeddedAppexBundleMismatchDiag() -> String? {
    guard let appexURL = Bundle.main.builtInPlugInsURL?
      .appendingPathComponent("DemarPacketTunnel.appex", isDirectory: true)
    else { return "embedded appex missing in PlugIns" }
    guard FileManager.default.fileExists(atPath: appexURL.path) else {
      return "embedded appex path missing: \(appexURL.path)"
    }
    guard let appexBundle = Bundle(url: appexURL) else { return "embedded appex bundle unreadable" }
    let id = appexBundle.bundleIdentifier ?? ""
    guard id == packetTunnelBundleId else {
      return "embedded appex bundle id=\(id) expected=\(packetTunnelBundleId)"
    }
    return nil
  }

  private func diagNeSnapshot(_ manager: NETunnelProviderManager, label: String) {
    let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
    let provider = proto?.providerBundleIdentifier ?? "?"
    let desc = manager.localizedDescription ?? "?"
    diag(
      "\(label): ne enabled=\(manager.isEnabled) provider=\(provider) "
        + "status=\(Self.statusLabel(manager.connection.status)) desc=\(desc)"
    )
  }
  #endif

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
