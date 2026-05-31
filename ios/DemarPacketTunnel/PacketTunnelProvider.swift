import Darwin
import Foundation
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

    return TunnelStartContext(
      uplinkHost: optionUplinkHost?.isEmpty == false ? optionUplinkHost : configuredUplinkHost,
      sessionId: (optionSessionId?.isEmpty == false ? optionSessionId : configuredSessionId) ?? "",
      connectSource: (optionSource?.isEmpty == false ? optionSource : configuredSource) ?? "unknown"
    )
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
  #if os(iOS)
  private var tunnelLifecycle: TunnelLifecycle?
  private var activeTunFd: Int64?
  private var activeIfaceName: String?
  private var activeAssetDir: String?
  private var activeUplinkHost: String?
  private var tunnelTeardownInFlight = false
  private var lastAppliedExcludedIPv4: [String] = []
  private var reconfigureInFlight = false
  private var reconfigurePendingReason: String?
  #endif
  #if os(macOS)
  private var coreChild: MacCoreChild?
  #endif
  private let startTunnelLock = NSLock()
  private var startTunnelInFlight = false

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    _ = TunnelBootstrap.once
    startTunnelLock.lock()
    if startTunnelInFlight {
      startTunnelLock.unlock()
      Self.diag("startTunnel ignored: already in flight")
      completionHandler(nil)
      return
    }
    startTunnelInFlight = true
    startTunnelLock.unlock()
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
        clearStartTunnelInFlight()
        fail("Missing shared config.json", code: 2, completionHandler: completionHandler)
        return
      }

      let startContext = TunnelStartContext.resolve(
        options: options,
        protocolConfiguration: protocolConfiguration as? NETunnelProviderProtocol
      )
      let sessionId = startContext.sessionId
      let connectSource = startContext.connectSource
      let uplinkHost = startContext.uplinkHost
      #if os(iOS)
      activeUplinkHost = uplinkHost
      tunnelTeardownInFlight = false
      lastAppliedExcludedIPv4 = []
      reconfigureInFlight = false
      reconfigurePendingReason = nil
      #endif
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
      let excludedIPv4 = try Self.resolveIPv4Addresses(host: uplinkHost)
      Self.diag(
        "start tunnel: uplinkHost=\(uplinkHost ?? "<none>") "
          + "excludedIPv4=\(excludedIPv4.isEmpty ? "<empty>" : excludedIPv4.joined(separator: ",")) "
          + "session=\(sessionId.isEmpty ? "<none>" : sessionId) source=\(connectSource)")

      #if os(iOS)
      self.startLibboxTunnel(
        cfgURL: cfgURL,
        excludedIPv4: excludedIPv4,
        uplinkHost: uplinkHost,
        completionHandler: completionHandler
      )
      #else
      let settings = Self.buildTunnelSettings(excludedIPv4: excludedIPv4)

      setTunnelNetworkSettings(settings) { [weak self] error in
        guard let self else {
          completionHandler(NSError(domain: "DemarVpn", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Tunnel released before completion.",
          ]))
          return
        }
        if let error {
          self.clearStartTunnelInFlight()
          self.fail(
            "setTunnelNetworkSettings failed: \(error.localizedDescription)",
            code: 7,
            completionHandler: completionHandler
          )
          return
        }
        VpnSharedStore.saveExtensionHeartbeat(phase: "setTunnelNetworkSettings-ok")

        guard let selectedTun = Self.resolveTunnelAfterSettings() else {
          self.clearStartTunnelInFlight()
          self.fail("Could not locate utun file descriptor.", code: 3, completionHandler: completionHandler)
          return
        }

        let tunFd = selectedTun.fd
        let ifaceName = selectedTun.name
        guard ifaceName.hasPrefix("utun"), Self.interfaceName(forUtunFd: tunFd) == ifaceName else {
          self.clearStartTunnelInFlight()
          self.fail(
            "Could not read utun interface name (fd=\(tunFd) interface=\(ifaceName)).",
            code: 4,
            completionHandler: completionHandler
          )
          return
        }
        Self.diag("utun selected: fd=\(tunFd) interface=\(ifaceName)")
        VpnSharedStore.saveExtensionHeartbeat(phase: "utun-ok")

        do {
          try Self.patchTunInboundName(at: cfgURL, interfaceName: ifaceName)
          Self.diag("patched tun inbound name: \(ifaceName)")
        } catch {
          self.clearStartTunnelInFlight()
          self.fail(
            "patchTunInboundName failed: \(error.localizedDescription)",
            code: 11,
            completionHandler: completionHandler
          )
          return
        }

        let assetDir: String
        do {
          let assetDirURL = try VpnAppGroup.assetDirectoryURL()
          assetDir = assetDirURL.path
          Self.diag(
            "core assets: \(Self.assetFileDescription(named: "geoip.db", in: assetDirURL)), "
              + "\(Self.assetFileDescription(named: "geosite.db", in: assetDirURL))")
        } catch {
          self.clearStartTunnelInFlight()
          self.fail(
            "asset directory lookup failed: \(error.localizedDescription)",
            code: 12,
            completionHandler: completionHandler
          )
          return
        }

        self.coreQueue.async {
          VpnSharedStore.saveExtensionHeartbeat(phase: "core-starting")
          do {
            let child = try MacCoreProcess.start(configPath: cfgURL.path, tunFd: tunFd, assetDir: assetDir)
            self.coreChild = child
            Self.diag("core subprocess started (pid=\(child.pid))")
            VpnSharedStore.saveExtensionHeartbeat(phase: "core-started")
            self.tunnelStartedAt = Date()
            VpnSharedStore.saveControlState("connected")
            Self.reloadControls()
            self.clearStartTunnelInFlight()
            DispatchQueue.main.async { completionHandler(nil) }
          } catch {
            VpnSharedStore.saveExtensionHeartbeat(phase: "core-failed")
            self.clearStartTunnelInFlight()
            self.fail(
              "core start error: \(error.localizedDescription)",
              code: 22,
              completionHandler: completionHandler
            )
          }
        }
      }
      #endif
    } catch {
      clearStartTunnelInFlight()
      fail(error.localizedDescription, code: 1, completionHandler: completionHandler)
    }
  }

  private func clearStartTunnelInFlight() {
    startTunnelLock.lock()
    startTunnelInFlight = false
    startTunnelLock.unlock()
  }

  #if os(iOS)
  private func startLibboxTunnel(
    cfgURL: URL,
    excludedIPv4: [String],
    uplinkHost: String?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let configJSON: String
    do {
      configJSON = try String(contentsOf: cfgURL, encoding: .utf8)
    } catch {
      clearStartTunnelInFlight()
      fail("read config failed: \(error.localizedDescription)", code: 13, completionHandler: completionHandler)
      return
    }

    let assetDir: URL
    do {
      assetDir = try VpnAppGroup.assetDirectoryURL()
      Self.diag(
        "core assets: \(Self.assetFileDescription(named: "geoip.db", in: assetDir)), "
          + "\(Self.assetFileDescription(named: "geosite.db", in: assetDir))"
      )
    } catch {
      clearStartTunnelInFlight()
      fail(
        "asset directory lookup failed: \(error.localizedDescription)",
        code: 12,
        completionHandler: completionHandler
      )
      return
    }

    coreQueue.async {
      VpnSharedStore.saveExtensionHeartbeat(phase: "core-starting")
      do {
        try IOSLibboxCore.start(
          provider: self,
          configJSON: configJSON,
          excludedIPv4: excludedIPv4,
          assetDir: assetDir
        )
        Self.diag("libbox service started")
        VpnSharedStore.saveExtensionHeartbeat(phase: "core-started")
        self.tunnelStartedAt = Date()
        self.applyIOSCoreStartedState(
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
        VpnSharedStore.saveExtensionHeartbeat(phase: "core-failed")
        self.clearStartTunnelInFlight()
        self.fail(
          "core start error: \(error.localizedDescription)",
          code: 22,
          completionHandler: completionHandler
        )
      }
    }
  }
  #endif

  #if os(iOS)
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
      excluded = try Self.resolveIPv4Addresses(host: uplink).sorted()
    } catch {
      Self.diag("reconfigure(\(reason)) prep failed: \(error.localizedDescription)")
      finishReconfigureCoalesced()
      return
    }

    let routesUnchanged = excluded == lastAppliedExcludedIPv4
    if routesUnchanged {
      let heartbeatFresh = VpnSharedStore.extensionHeartbeatIsFresh(maxAge: 30)
      if VpnReconfigurePolicy.shouldSoftRestartWhenRoutesUnchanged(
        reason: reason,
        heartbeatFresh: heartbeatFresh,
        tunHealthy: IOSLibboxCore.isRunning
      ) {
        Self.diag(
          "reconfigure(\(reason)) recovery soft-restart heartbeatFresh=\(heartbeatFresh) libboxRunning=\(IOSLibboxCore.isRunning)"
        )
        runSoftCoreRestart(reason: reason, cfgPath: cfgPath, excluded: excluded, assetDir: assetDir)
        return
      }
      Self.diag("reconfigure(\(reason)) skipped: routes unchanged (stable tunnel)")
      finishReconfigureCoalesced()
      return
    }

    runSoftCoreRestart(reason: reason, cfgPath: cfgPath, excluded: excluded, assetDir: assetDir)
  }

  private func runSoftCoreRestart(reason: String, cfgPath: String, excluded: [String], assetDir: String) {
    let configJSON: String
    do {
      configJSON = try String(contentsOf: URL(fileURLWithPath: cfgPath), encoding: .utf8)
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
    }
    finishReconfigureCoalesced()
  }

  private func finishReconfigureCoalesced() {
    let pending = reconfigurePendingReason
    reconfigurePendingReason = nil
    reconfigureInFlight = false
    guard let pending, !tunnelTeardownInFlight else { return }
    reconfigureInFlight = true
    runReconfigurePass(reason: pending)
  }
  #endif

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    #if os(iOS)
    tunnelTeardownInFlight = true
    reconfigureInFlight = false
    reconfigurePendingReason = nil
    tunnelLifecycle?.stop()
    tunnelLifecycle = nil
    #endif
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
    clearStartTunnelInFlight()
    coreQueue.async {
      #if os(iOS)
      IOSLibboxCore.stop()
      #else
      MacCoreProcess.stop(self.coreChild)
      self.coreChild = nil
      #endif
      self.clearStartTunnelInFlight()
      VpnSharedStore.clearExtensionHeartbeat()
      #if os(iOS)
      self.activeTunFd = nil
      self.activeIfaceName = nil
      self.activeAssetDir = nil
      self.activeUplinkHost = nil
      #endif
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
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard String(data: messageData, encoding: .utf8) == "hardRestartCore" else {
      completionHandler?(nil)
      return
    }
    hardRestartCore { error in
      if let error {
        completionHandler?(Data("err:\(error.localizedDescription)".utf8))
      } else {
        completionHandler?(Data("ok".utf8))
      }
    }
  }

  private func hardRestartCore(completion: @escaping (Error?) -> Void) {
    #if os(iOS)
    guard !tunnelTeardownInFlight else {
      completion(NSError(domain: "DemarVpn", code: 42, userInfo: [
        NSLocalizedDescriptionKey: "Туннель останавливается.",
      ]))
      return
    }
    #endif
    coreQueue.async { [weak self] in
      self?.runHardRestartCore(completion: completion)
    }
  }

  private func runHardRestartCore(completion: @escaping (Error?) -> Void) {
    appendDiagLine("hardRestartCore")
    #if os(iOS)
    IOSLibboxCore.stop()
    #else
    MacCoreProcess.stop(coreChild)
    coreChild = nil
    #endif
    do {
      let cfgURL = try VpnAppGroup.configURL()
      #if os(macOS)
      guard let tun = Self.resolveTunnelAfterSettings() else {
        throw NSError(domain: "DemarVpn", code: 43, userInfo: [
          NSLocalizedDescriptionKey: "Не найден utun.",
        ])
      }
      try Self.patchTunInboundName(at: cfgURL, interfaceName: tun.name)
      let assetDir = try VpnAppGroup.assetDirectoryURL().path
      coreChild = try MacCoreProcess.start(configPath: cfgURL.path, tunFd: tun.fd, assetDir: assetDir)
      #else
      let configJSON = try String(contentsOf: cfgURL, encoding: .utf8)
      let excluded = try Self.resolveIPv4Addresses(host: activeUplinkHost).sorted()
      let assetDir = try VpnAppGroup.assetDirectoryURL()
      try IOSLibboxCore.start(
        provider: self,
        configJSON: configJSON,
        excludedIPv4: excluded,
        assetDir: assetDir
      )
      applyIOSCoreStartedState(
        excludedIPv4: excluded,
        assetDirPath: assetDir.path,
        uplinkHost: activeUplinkHost
      )
      #endif
      VpnSharedStore.saveExtensionHeartbeat(phase: "running")
      Self.diag("hardRestartCore ok")
      DispatchQueue.main.async { completion(nil) }
    } catch {
      Self.diag("hardRestartCore failed: \(error.localizedDescription)")
      DispatchQueue.main.async { completion(error) }
    }
  }

  #if os(iOS)
  private func applyIOSCoreStartedState(
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
  #endif

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

  private static func buildTunnelSettings(excludedIPv4: [String]) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.255"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    ipv4.excludedRoutes = excludedIPv4.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
    settings.ipv4Settings = ipv4
    settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
    return settings
  }

  private static func resolveIPv4Addresses(host: String?) throws -> [String] {
    let clean = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if clean.isEmpty { return [] }
    if isIPv4(clean) { return [clean] }

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
    var resultPtr: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(clean, nil, &hints, &resultPtr)
    guard rc == 0 else {
      throw NSError(
        domain: "DemarVpn",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "DNS lookup failed for \(clean): \(String(cString: gai_strerror(rc)))"]
      )
    }
    defer { if let resultPtr { freeaddrinfo(resultPtr) } }

    var out: [String] = []
    var ptr = resultPtr
    while let info = ptr?.pointee {
      if info.ai_family == AF_INET, let sa = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
        var addr = sa.pointee.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
          out.append(String(cString: buf))
        }
      }
      ptr = info.ai_next
    }
    out = Array(Set(out)).sorted()
    if out.isEmpty {
      throw NSError(
        domain: "DemarVpn",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "DNS lookup returned no IPv4 for \(clean)"]
      )
    }
    return out
  }

  private static func isIPv4(_ s: String) -> Bool {
    var a = in_addr()
    return s.withCString { inet_pton(AF_INET, $0, &a) } == 1
  }

  private static let sysprotoControl: Int32 = 2
  private static let utunOptIfName: Int32 = 2

  /// Call only after setTunnelNetworkSettings succeeds.
  private static func resolveTunnelAfterSettings() -> (fd: Int64, name: String)? {
    #if os(macOS)
    // Do not use tunnelFileDescriptorViaControl(): it returns a utun_control socket,
    // not the packet I/O fd sing-box needs (causes "bad file descriptor" on start).
    for attempt in 0..<12 {
      if let picked = selectUtunCandidate(),
         interfaceName(forUtunFd: picked.fd) == picked.name
      {
        return picked
      }
      if attempt < 11 { Thread.sleep(forTimeInterval: 0.05) }
    }
    return nil
    #else
    guard let picked = selectUtunCandidate(),
          interfaceName(forUtunFd: picked.fd) == picked.name
    else { return nil }
    return picked
    #endif
  }

  /// Fallback: scan utun fds when control socket lookup is unavailable.
  private static func findUtunCandidates() -> [(fd: Int64, name: String)] {
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    let utunPrefix = Array("utun".utf8)
    var out: [(fd: Int64, name: String)] = []
    for fd: Int32 in 0...1024 {
      var len = socklen_t(buf.count)
      buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
      if getsockopt(fd, 2, 2, &buf, &len) != 0 {
        continue
      }
      let checkLen = min(Int(len), buf.count)
      guard checkLen >= utunPrefix.count else { continue }
      var ok = true
      for i in 0..<utunPrefix.count {
        if UInt8(bitPattern: buf[i]) != utunPrefix[i] {
          ok = false
          break
        }
      }
      if ok {
        out.append((Int64(fd), String(cString: buf)))
      }
    }
    return out
  }

  private static func selectUtunCandidate() -> (fd: Int64, name: String)? {
    let candidates = findUtunCandidates().filter { $0.name.hasPrefix("utun") }
    return candidates.max(by: { $0.fd < $1.fd })
  }

  private static func interfaceName(forUtunFd fd: Int64) -> String? {
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    var len = socklen_t(buf.count)
    guard getsockopt(Int32(fd), sysprotoControl, utunOptIfName, &buf, &len) == 0 else {
      return nil
    }
    return String(cString: buf)
  }

  private static func patchTunInboundName(at url: URL, interfaceName: String) throws {
    let data = try Data(contentsOf: url)
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var inbounds = root["inbounds"] as? [[String: Any]]
    else {
      throw NSError(domain: "DemarVpn", code: 11, userInfo: [
        NSLocalizedDescriptionKey: "Invalid core JSON (expected object with inbounds[]).",
      ])
    }

    var patched = false
    for i in 0..<inbounds.count {
      let isTunInbound = (inbounds[i]["protocol"] as? String) == "tun" || (inbounds[i]["type"] as? String) == "tun"
      guard isTunInbound else { continue }
      if var settings = inbounds[i]["settings"] as? [String: Any] {
        settings["name"] = interfaceName
        inbounds[i]["settings"] = settings
      } else {
        inbounds[i]["interface_name"] = interfaceName
      }
      patched = true
      break
    }

    guard patched else {
      throw NSError(domain: "DemarVpn", code: 12, userInfo: [
        NSLocalizedDescriptionKey: "No tun inbound found to patch.",
      ])
    }

    root["inbounds"] = inbounds
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: url, options: [.atomic])
  }

  private static func assetFileDescription(named name: String, in dir: URL) -> String {
    let fileURL = dir.appendingPathComponent(name, isDirectory: false)
    let path = fileURL.path
    guard FileManager.default.fileExists(atPath: path) else {
      return "\(name)=missing"
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    return "\(name)=present:\(size)B"
  }

  private static func diag(_ message: String) {
    logLine(message)
    appendDiagLine(message)
  }

  private func fail(
    _ message: String,
    code: Int,
    completionHandler: @escaping (Error?) -> Void
  ) {
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
