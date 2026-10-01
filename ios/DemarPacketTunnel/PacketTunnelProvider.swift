import Darwin
import Foundation
import Network
import NetworkExtension
#if canImport(WidgetKit)
import WidgetKit
#endif

private func logLine(_ message: String) {
  NSLog("[DemarPacketTunnel] %@", message)
}

private func appendDiagLine(_ message: String) {
  #if os(macOS)
  VpnSharedStore.appendPendingUiDiagLine("[mac] \(message)")
  #else
  VpnSharedStore.appendPendingUiDiagLine("[ios] \(message)")
  #endif
}

private struct TunnelStartContext {
  let uplinkHost: String?
  let uplinkIPv4s: [String]
  let sessionId: String
  let connectSource: String

  static func resolve(
    options: [String: NSObject]?,
    protocolConfiguration: NETunnelProviderProtocol?
  ) -> TunnelStartContext {
    let optionUplinkHost = (options?[VpnTunnelProviderKeys.uplinkHost] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let configuredUplinkHost =
      (protocolConfiguration?.providerConfiguration?[VpnTunnelProviderKeys.uplinkHost] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let optionSessionId = (options?[VpnTunnelProviderKeys.sessionId] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let configuredSessionId =
      (protocolConfiguration?.providerConfiguration?[VpnTunnelProviderKeys.sessionId] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let optionSource = (options?[VpnTunnelProviderKeys.connectSource] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let configuredSource =
      (protocolConfiguration?.providerConfiguration?[VpnTunnelProviderKeys.connectSource] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let optionIPs = Self.parseIPv4List(options?[VpnTunnelProviderKeys.uplinkIPv4s] as? String)

    return TunnelStartContext(
      uplinkHost: optionUplinkHost?.isEmpty == false ? optionUplinkHost : configuredUplinkHost,
      uplinkIPv4s: optionIPs,
      sessionId: (optionSessionId?.isEmpty == false ? optionSessionId : configuredSessionId) ?? "",
      connectSource: (optionSource?.isEmpty == false ? optionSource : configuredSource) ?? "unknown"
    )
  }

  private static func parseIPv4List(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    return raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

  private enum TunnelBootstrap {
    static let once: Void = {
      VpnSharedStore.saveExtensionHeartbeat(phase: "bootstrap")
      #if os(macOS)
      VpnSharedStore.appendJournalLine("[mac] extension process loaded")
      #else
      VpnSharedStore.appendJournalLine("[ios] extension process loaded")
      #endif
    }()
  }

  override init() {
    _ = TunnelBootstrap.once
    super.init()
    VpnSharedStore.saveExtensionHeartbeat(phase: "init")
    appendDiagLine(
      "PacketTunnelProvider init appGroup=\(VpnAppGroup.containerURL?.path ?? "nil")"
    )
  }

  private let coreQueue = DispatchQueue(label: "vpn.demar.core", qos: .userInitiated)
  private var currentSessionId: String?
  private var tunnelStartedAt: Date?
  private var activeAssetDir: String?
  private var activeUplinkHost: String?
  private var tunnelTeardownInFlight = false
  private var lastAppliedExcludedIPv4: [String] = []
  private var reconfigureInFlight = false
  private var reconfigurePendingReason: String?
  private var tunnelLifecycle: TunnelLifecycle?
  private let startTunnelLock = NSLock()
  private var startTunnelInFlight = false
  private let sessionGenerationLock = NSLock()
  private var sessionGeneration: UInt64 = 0

  private func beginSessionGeneration() -> UInt64 {
    sessionGenerationLock.lock()
    defer { sessionGenerationLock.unlock() }
    sessionGeneration &+= 1
    return sessionGeneration
  }

  private func invalidateSessionGeneration() {
    sessionGenerationLock.lock()
    sessionGeneration &+= 1
    sessionGenerationLock.unlock()
  }

  private func isCurrentSessionGeneration(_ generation: UInt64) -> Bool {
    sessionGenerationLock.lock()
    defer { sessionGenerationLock.unlock() }
    return sessionGeneration == generation
  }

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    _ = TunnelBootstrap.once
    startTunnelLock.lock()
    if startTunnelInFlight {
      startTunnelLock.unlock()
      let error = NSError(domain: "DemarVpn", code: 43, userInfo: [
        NSLocalizedDescriptionKey: "Tunnel start is already in progress.",
      ])
      Self.diag("startTunnel rejected: already in flight")
      completionHandler(error)
      return
    }
    startTunnelInFlight = true
    startTunnelLock.unlock()
    let generation = beginSessionGeneration()
    logLine("startTunnel invoked")
    VpnSharedStore.clearTunnelStartFailure()
    VpnSharedStore.saveExtensionHeartbeat(phase: "startTunnel")
    Self.diag(
      "startTunnel entry appGroup=\(VpnAppGroup.containerURL?.path ?? "nil") "
        + "configExists=\(FileManager.default.fileExists(atPath: (try? VpnAppGroup.configURL().path) ?? ""))"
    )
    VpnSharedStore.saveControlState("connecting")
    Self.reloadControls()
    do {
      let cfgURL = try VpnAppGroup.configURL()
      guard FileManager.default.fileExists(atPath: cfgURL.path) else {
        fail("Missing shared config.json", code: 2, generation: generation, completionHandler: completionHandler)
        return
      }

      let startContext = TunnelStartContext.resolve(
        options: options,
        protocolConfiguration: protocolConfiguration as? NETunnelProviderProtocol
      )
      let sessionId = startContext.sessionId
      let connectSource = startContext.connectSource
      let uplinkHost = startContext.uplinkHost
      guard uplinkHost?.isEmpty == false else {
        fail(
          "Missing uplink host; refusing unsafe full-tunnel start",
          code: 11,
          generation: generation,
          completionHandler: completionHandler
        )
        return
      }
      activeUplinkHost = uplinkHost
      lastAppliedExcludedIPv4 = []
      reconfigureInFlight = false
      reconfigurePendingReason = nil
      #if os(iOS)
      if !sessionId.isEmpty,
         let prior = VpnSharedStore.loadActiveSession()?["sessionId"],
         prior == sessionId,
         VpnSharedStore.extensionHeartbeatIsFresh(maxAge: 120)
      {
        Self.diag("extension reload suspected (same session)")
      }
      #endif
      if !sessionId.isEmpty {
        currentSessionId = sessionId
        VpnSharedStore.saveActiveSession(sessionId: sessionId, triggerSource: connectSource)
      }
      let excludedIPv4: [String]
      if !startContext.uplinkIPv4s.isEmpty {
        excludedIPv4 = startContext.uplinkIPv4s
      } else {
        excludedIPv4 = try UplinkIPv4Resolver.resolve(uplinkHost)
      }
      Self.diag(
        "start tunnel: uplinkHost=\(uplinkHost ?? "<none>") "
          + "excludedIPv4=\(excludedIPv4.isEmpty ? "<empty>" : excludedIPv4.joined(separator: ",")) "
          + "ipsFromOptions=\(!startContext.uplinkIPv4s.isEmpty) "
          + "session=\(sessionId.isEmpty ? "<none>" : sessionId) source=\(connectSource)")

      self.startLibboxTunnel(
        cfgURL: cfgURL,
        excludedIPv4: excludedIPv4,
        uplinkHost: uplinkHost,
        generation: generation,
        completionHandler: completionHandler
      )
    } catch {
      fail(error.localizedDescription, code: 1, generation: generation, completionHandler: completionHandler)
    }
  }

  private func clearStartTunnelInFlight() {
    startTunnelLock.lock()
    startTunnelInFlight = false
    startTunnelLock.unlock()
  }

  private func startLibboxTunnel(
    cfgURL: URL,
    excludedIPv4: [String],
    uplinkHost: String?,
    generation: UInt64,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let configJSON: String
    do {
      let raw = try String(contentsOf: cfgURL, encoding: .utf8)
      configJSON = try Self.configWithMergedUplinkIPs(raw, excludedIPv4: excludedIPv4)
    } catch {
      fail(
        "read config failed: \(error.localizedDescription)",
        code: 13,
        generation: generation,
        completionHandler: completionHandler
      )
      return
    }

    let assetDir: URL
    do {
      assetDir = try VpnAppGroup.assetDirectoryURL()
      Self.diag(
        "core assets: \(Self.assetFileDescription(named: "geoip.db", in: assetDir)), "
          + "\(Self.assetFileDescription(named: "geosite.db", in: assetDir)), "
          + "\(Self.assetFileDescription(named: CoreBundleAssets.adsFile, in: assetDir))"
      )
    } catch {
      fail(
        "asset directory lookup failed: \(error.localizedDescription)",
        code: 12,
        generation: generation,
        completionHandler: completionHandler
      )
      return
    }

    coreQueue.async {
      if self.tunnelTeardownInFlight {
        IOSLibboxCore.stop()
        self.tunnelTeardownInFlight = false
      }
      guard self.isCurrentSessionGeneration(generation) else {
        self.clearStartTunnelInFlight()
        DispatchQueue.main.async { completionHandler(CancellationError()) }
        return
      }
      VpnSharedStore.saveExtensionHeartbeat(phase: "core-starting")
      do {
        try IOSLibboxCore.start(
          provider: self,
          configJSON: configJSON,
          excludedIPv4: excludedIPv4,
          assetDir: assetDir
        )
        let snapshot = Self.coreSnapshot(configJSON)
        IOSLibboxCore.markSession(
          id: self.currentSessionId ?? "unknown",
          protocolName: snapshot.protocolName,
          endpoint: snapshot.endpoint
        )
        guard self.isCurrentSessionGeneration(generation) else { throw CancellationError() }
        // iOS 26 NE: pre-capture BSD connect to mixed inbound → EADDRNOTAVAIL.
        // Gate start on path settle + deferred route install, not a TCP data probe.
        try self.bringUpTrafficCapture()
        guard self.isCurrentSessionGeneration(generation) else { throw CancellationError() }
        Self.diag("libbox service started (capture active, path settled)")
        VpnSharedStore.saveExtensionHeartbeat(phase: "core-started")
        self.tunnelStartedAt = Date()
        self.applyCoreStartedState(
          excludedIPv4: excludedIPv4,
          assetDirPath: assetDir.path,
          uplinkHost: uplinkHost
        )
        VpnSharedStore.saveControlState("connected")
        Self.reloadControls()
        VpnSharedStore.clearTunnelStartFailure()
        self.clearStartTunnelInFlight()
        DispatchQueue.main.async { completionHandler(nil) }
      } catch {
        guard self.isCurrentSessionGeneration(generation) else {
          IOSLibboxCore.stop()
          self.clearStartTunnelInFlight()
          DispatchQueue.main.async { completionHandler(CancellationError()) }
          return
        }
        VpnSharedStore.saveExtensionHeartbeat(phase: "core-failed")
        self.fail(
          "core start error: \(error.localizedDescription)",
          code: 22,
          generation: generation,
          completionHandler: completionHandler
        )
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    appendDiagLine("device sleep (disconnectOnSleep=false, tunnel stays up)")
    completionHandler()
  }

  override func wake() {
    appendDiagLine("device wake")
    tunnelLifecycle?.scheduleRevalidate(reason: "wake")
  }

  /// Re-applies routes and restarts core after network path change or wake (extension-only).
  func reconfigureTunnel(reason: String) {
    guard !tunnelTeardownInFlight else { return }
    guard IOSLibboxCore.isRunning, activeAssetDir != nil else { return }

    coreQueue.async { [weak self] in
      guard let self else { return }
      if self.reconfigureInFlight {
        self.reconfigurePendingReason = reason
        Self.diag("reconfigure(\(reason)) coalesced (in-flight)")
        return
      }
      self.reconfigureInFlight = true
      self.runReconfigurePass(reason: reason)
    }
  }

  private func runReconfigurePass(reason: String) {
    guard !tunnelTeardownInFlight else {
      finishReconfigureCoalesced()
      return
    }
    guard IOSLibboxCore.isRunning, let assetDir = activeAssetDir else {
      finishReconfigureCoalesced()
      return
    }
    let uplink = activeUplinkHost
    let cfgPath: String
    let excluded: [String]
    do {
      cfgPath = try VpnAppGroup.configURL().path
      excluded = try UplinkIPv4Resolver.resolve(uplink)
    } catch {
      Self.diag("reconfigure(\(reason)) prep failed: \(error.localizedDescription)")
      finishReconfigureCoalesced()
      return
    }

    let routesUnchanged = excluded == lastAppliedExcludedIPv4
    if routesUnchanged, !VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(reason: reason) {
      Self.diag("reconfigure(\(reason)) skipped: routes unchanged (stable tunnel)")
      finishReconfigureCoalesced()
      return
    }

    runSoftCoreRestart(reason: reason, cfgPath: cfgPath, excluded: excluded, assetDir: assetDir)
  }

  private func runSoftCoreRestart(reason: String, cfgPath: String, excluded: [String], assetDir: String) {
    let configJSON: String
    do {
      let raw = try String(contentsOf: URL(fileURLWithPath: cfgPath), encoding: .utf8)
      configJSON = try Self.configWithMergedUplinkIPs(raw, excludedIPv4: excluded)
    } catch {
      Self.diag("reconfigure(\(reason)) read config failed: \(error.localizedDescription)")
      finishReconfigureCoalesced()
      return
    }
    reasserting = true
    var err: NSError?
    let ok: Bool
    do {
      try IOSLibboxCore.reload(configJSON: configJSON, excludedIPv4: excluded)
      ok = true
    } catch {
      err = error as NSError
      ok = false
    }
    reasserting = false
    if ok {
      lastAppliedExcludedIPv4 = excluded
      activeAssetDir = assetDir
      VpnSharedStore.saveExtensionHeartbeat(phase: "running")
      Self.diag(
        "reconfigure(\(reason)) ok excluded=\(excluded.isEmpty ? "<empty>" : excluded.joined(separator: ","))"
      )
    } else {
      let msg = err?.localizedDescription ?? "unknown"
      Self.diag("reconfigure(\(reason)) libbox reload failed: \(msg)")
      recoverAfterReloadFailure(
        reason: reason,
        configJSON: configJSON,
        excluded: excluded,
        assetDir: assetDir
      )
    }
    finishReconfigureCoalesced()
  }

  private func recoverAfterReloadFailure(
    reason: String,
    configJSON: String,
    excluded: [String],
    assetDir: String
  ) {
    IOSLibboxCore.stop()
    do {
      try IOSLibboxCore.start(
        provider: self,
        configJSON: configJSON,
        excludedIPv4: excluded,
        assetDir: URL(fileURLWithPath: assetDir, isDirectory: true)
      )
      try bringUpTrafficCapture()
      applyCoreStartedState(
        excludedIPv4: excluded,
        assetDirPath: assetDir,
        uplinkHost: activeUplinkHost
      )
      VpnSharedStore.saveExtensionHeartbeat(phase: "running")
      Self.diag("reconfigure(\(reason)) recovered with hard restart")
    } catch {
      let message = "reconfigure(\(reason)) recovery failed: \(error.localizedDescription)"
      VpnSharedStore.saveControlState("error")
      VpnSharedStore.saveTunnelStartFailure(message)
      VpnSharedStore.saveExtensionHeartbeat(phase: "failed-reconfigure")
      Self.diag(message)
      DispatchQueue.main.async { self.cancelTunnelWithError(error) }
    }
  }

  private func finishReconfigureCoalesced() {
    let pending = reconfigurePendingReason
    reconfigurePendingReason = nil
    reconfigureInFlight = false
    guard let pending, !tunnelTeardownInFlight else { return }
    reconfigureInFlight = true
    runReconfigurePass(reason: pending)
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    invalidateSessionGeneration()
    tunnelTeardownInFlight = true
    reconfigureInFlight = false
    reconfigurePendingReason = nil
    tunnelLifecycle?.stop()
    tunnelLifecycle = nil
    let reasonLabel = Self.stopReasonLabel(reason)
    let advice = Self.stopReasonAdvice(reason)
    logLine("stopTunnel reason=\(reasonLabel) raw=\(reason.rawValue)")
    let pendingStop = VpnSharedStore.consumePendingStopContext()
    let activeSession = VpnSharedStore.loadActiveSession()
    let sessionId = (pendingStop?["sessionId"]?.isEmpty == false
      ? pendingStop?["sessionId"]
      : nil)
      ?? currentSessionId
      ?? activeSession?["sessionId"]
    let triggerSource = (pendingStop?["triggerSource"]?.isEmpty == false
      ? pendingStop?["triggerSource"]
      : nil)
      ?? (reason == .userInitiated ? "externalUserOrSystem" : "system")
    let uptimeSinceStartSec: Int? = {
      guard let started = tunnelStartedAt else { return nil }
      let dt = Int(Date().timeIntervalSince(started))
      return dt >= 0 ? dt : 0
    }()
    VpnSharedStore.saveLastTunnelStopReason(
      label: reasonLabel,
      code: Int(reason.rawValue),
      sessionId: sessionId,
      triggerSource: triggerSource,
      uptimeSinceStartSec: uptimeSinceStartSec
    )
    appendDiagLine(
      "tunnel stop: \(reasonLabel) raw=\(reason.rawValue) source=\(triggerSource) "
        + "session=\(sessionId ?? "<none>") \(advice)"
    )
    if reason == .userInitiated, triggerSource == "externalUserOrSystem" {
      appendDiagLine("tunnel stop classified as external/system user action")
    }
    if reason == .configurationDisabled {
      appendDiagLine("configuration disabled by system: verify VPN profile remains enabled in iOS Settings > VPN")
    }
    if reason == .providerFailed, let lastCore = VpnSharedStore.readLastCoreErrorLineSnapshot() {
      appendDiagLine("tunnel stop providerFailed: core_last_error=\(lastCore)")
    }
    coreQueue.async {
      IOSLibboxCore.stop()
      self.clearStartTunnelInFlight()
      VpnSharedStore.clearExtensionHeartbeat()
      self.activeAssetDir = nil
      self.activeUplinkHost = nil
      // User may disconnect from Settings; persisted NEOnDemandRuleConnect would otherwise reconnect.
      VpnTunnelController.shared.disableOnDemandAutoReconnect { err in
        if let err {
          logLine("disableOnDemandAutoReconnect: \(err.localizedDescription)")
        }
      }
      self.currentSessionId = nil
      self.tunnelStartedAt = nil
      VpnSharedStore.clearActiveSession()
      VpnSharedStore.saveControlState("disconnected")
      Self.reloadControls()
      self.tunnelTeardownInFlight = false
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let text = String(data: messageData, encoding: .utf8) ?? ""
    func reply(_ err: Error?) {
      if let err {
        completionHandler?(Data("err:\(err.localizedDescription)".utf8))
      } else {
        completionHandler?(Data("ok".utf8))
      }
    }
    if text == "hardRestartCore" {
      hardRestartCore(completion: reply)
      return
    }
    if text.hasPrefix("reapplyExcludes:") {
      let ips = text.dropFirst("reapplyExcludes:".count)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      coreQueue.async {
        do {
          try IOSLibboxCore.reapplyExcludedIPv4(ips)
          Self.diag("reapplyExcludes count=\(ips.count)")
          DispatchQueue.main.async { reply(nil) }
        } catch {
          DispatchQueue.main.async { reply(error) }
        }
      }
      return
    }
    completionHandler?(nil)
  }

  private func hardRestartCore(completion: @escaping (Error?) -> Void) {
    guard !tunnelTeardownInFlight else {
      completion(NSError(domain: "DemarVpn", code: 42, userInfo: [
        NSLocalizedDescriptionKey: "Туннель останавливается.",
      ]))
      return
    }
    coreQueue.async { [weak self] in
      self?.runHardRestartCore(completion: completion)
    }
  }

  private func runHardRestartCore(completion: @escaping (Error?) -> Void) {
    appendDiagLine("hardRestartCore")
    IOSLibboxCore.stop()
    do {
      let cfgURL = try VpnAppGroup.configURL()
      let raw = try String(contentsOf: cfgURL, encoding: .utf8)
      let excluded = try UplinkIPv4Resolver.resolve(activeUplinkHost)
      let configJSON = try Self.configWithMergedUplinkIPs(raw, excludedIPv4: excluded)
      let assetDir = try VpnAppGroup.assetDirectoryURL()
      try IOSLibboxCore.start(
        provider: self,
        configJSON: configJSON,
        excludedIPv4: excluded,
        assetDir: assetDir
      )
      try bringUpTrafficCapture()
      applyCoreStartedState(
        excludedIPv4: excluded,
        assetDirPath: assetDir.path,
        uplinkHost: activeUplinkHost
      )
      VpnSharedStore.saveExtensionHeartbeat(phase: "running")
      Self.diag("hardRestartCore ok")
      DispatchQueue.main.async { completion(nil) }
    } catch {
      Self.diag("hardRestartCore failed: \(error.localizedDescription)")
      DispatchQueue.main.async { completion(error) }
    }
  }

  /// Deferred TUN → install full routes → resume sticky default iface.
  /// Do not wait for NWPath `.satisfied` after capture: on iOS the NE path often
  /// stays `.unsatisfied` with phys ifaces still listed (was costing ~15s every connect).
  private func bringUpTrafficCapture() throws {
    Self.waitForSatisfiedPath(timeoutSeconds: 2)
    VpnSharedStore.saveExtensionHeartbeat(phase: "core-settling")
    try IOSLibboxCore.activateTrafficCapture()
    IOSLibboxCore.resumeDefaultInterfaceAfterCapture()
  }

  private func applyCoreStartedState(
    excludedIPv4: [String],
    assetDirPath: String,
    uplinkHost: String?
  ) {
    lastAppliedExcludedIPv4 = excludedIPv4.sorted()
    activeAssetDir = assetDirPath
    tunnelLifecycle?.stop()
    tunnelLifecycle = TunnelLifecycle(provider: self)
    tunnelLifecycle?.start(uplinkHost: uplinkHost)
  }

  private static func reloadControls() {
    VpnControlReloader.reloadControls()
  }

  private static func stopReasonLabel(_ reason: NEProviderStopReason) -> String {
    switch reason {
    case .none:
      return "none"
    case .userInitiated:
      return "userInitiated"
    case .providerFailed:
      return "providerFailed"
    case .noNetworkAvailable:
      return "noNetworkAvailable"
    case .unrecoverableNetworkChange:
      return "unrecoverableNetworkChange"
    case .providerDisabled:
      return "providerDisabled"
    case .authenticationCanceled:
      return "authenticationCanceled"
    case .configurationFailed:
      return "configurationFailed"
    case .idleTimeout:
      return "idleTimeout"
    case .configurationDisabled:
      return "configurationDisabled"
    case .configurationRemoved:
      return "configurationRemoved"
    case .superceded:
      return "superceded"
    case .userLogout:
      return "userLogout"
    case .userSwitch:
      return "userSwitch"
    case .connectionFailed:
      return "connectionFailed"
    case .sleep:
      return "sleep"
    case .appUpdate:
      return "appUpdate"
    case .internalError:
      return "internalError"
    @unknown default:
      return "unknown"
    }
  }

  private static func stopReasonAdvice(_ reason: NEProviderStopReason) -> String {
    switch reason {
    case .connectionFailed:
      return "advice=check uplink route exclusion and server reachability"
    case .unrecoverableNetworkChange:
      return "advice=network path changed; reconnect with refreshed uplink"
    case .noNetworkAvailable:
      return "advice=no active network; wait for connectivity and reconnect"
    case .providerFailed:
      return "advice=inspect core log for fatal error"
    default:
      return "advice=none"
    }
  }

  private static func configWithMergedUplinkIPs(_ configJSON: String, excludedIPv4: [String]) throws -> String {
    try SingBoxConfigBuilder.mergeDirectIPs(excludedIPv4, into: configJSON)
  }

  private static func coreSnapshot(_ configJSON: String) -> (protocolName: String, endpoint: String) {
    guard let data = configJSON.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let outbounds = root["outbounds"] as? [[String: Any]],
          let proxy = outbounds.first(where: { ($0["tag"] as? String) == SingBoxConfigConstants.proxyTag })
    else { return ("unknown", "unknown") }
    return (proxy["type"] as? String ?? "unknown", proxy["server"] as? String ?? "unknown")
  }

  /// Blocks until NWPath is satisfied or timeout. Used before installing full routes.
  private static func waitForSatisfiedPath(
    timeoutSeconds: TimeInterval,
    onTick: (() -> Void)? = nil
  ) {
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "vpn.demar.path-wait")
    let semaphore = DispatchSemaphore(value: 0)
    monitor.pathUpdateHandler = { path in
      if path.status == .satisfied {
        semaphore.signal()
      }
    }
    monitor.start(queue: queue)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var timedOut = true
    while Date() < deadline {
      onTick?()
      if semaphore.wait(timeout: .now() + 2) == .success {
        timedOut = false
        break
      }
    }
    monitor.cancel()
    if timedOut {
      diag("path wait timed out after \(Int(timeoutSeconds))s; activating capture anyway")
    } else {
      diag("path satisfied; activating capture")
    }
  }

  private static func assetFileDescription(named name: String, in dir: URL) -> String {
    let size = CoreBundleAssets.fileSize(name, in: dir)
    return size > 0 ? "\(name)=present:\(size)B" : "\(name)=missing"
  }

  private static func diag(_ message: String) {
    logLine(message)
    appendDiagLine(message)
  }

  private func fail(
    _ message: String,
    code: Int,
    generation: UInt64? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    if let generation, !isCurrentSessionGeneration(generation) {
      clearStartTunnelInFlight()
      DispatchQueue.main.async { completionHandler(CancellationError()) }
      return
    }
    clearStartTunnelInFlight()
    VpnSharedStore.saveControlState("error")
    VpnSharedStore.saveExtensionHeartbeat(phase: "failed-\(code)")
    Self.reloadControls()
    Self.diag(message)
    VpnSharedStore.saveTunnelStartFailure(message)
    let error = NSError(domain: "DemarVpn", code: code, userInfo: [
      NSLocalizedDescriptionKey: message,
    ])
    if Thread.isMainThread {
      completionHandler(error)
    } else {
      DispatchQueue.main.async { completionHandler(error) }
    }
  }
}
