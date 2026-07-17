import Darwin
import Foundation
import NetworkExtension
#if canImport(WidgetKit)
import WidgetKit
#endif

private func logLine(_ message: String) {
  NSLog("[DemarPacketTunnel] %@", message)
}

private enum TunnelDataProbe {
  struct Result {
    let ok: Bool
    let detail: String
  }

  static func run() -> Result {
    let connect = request(
      "CONNECT www.cloudflare.com:443 HTTP/1.1\r\nHost: www.cloudflare.com:443\r\nConnection: close\r\n\r\n",
      expectedStatus: 200
    )
    guard connect.ok else { return connect }
    return request(
      "GET http://cp.cloudflare.com/generate_204 HTTP/1.1\r\nHost: cp.cloudflare.com\r\nConnection: close\r\n\r\n",
      expectedStatus: 204
    )
  }

  private static func request(_ request: String, expectedStatus: Int) -> Result {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return Result(ok: false, detail: "proxy socket: \(String(cString: strerror(errno)))") }
    defer { close(descriptor) }

    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var timeout = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(SingBoxConfigConstants.diagnosticPort).bigEndian)
    _ = SingBoxConfigConstants.diagnosticHost.withCString {
      inet_pton(AF_INET, $0, &address.sin_addr)
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      return Result(ok: false, detail: "diagnostic proxy connect: \(String(cString: strerror(errno)))")
    }

    let sent = request.utf8CString.withUnsafeBytes {
      send(descriptor, $0.baseAddress, $0.count - 1, 0)
    }
    guard sent > 0 else {
      return Result(ok: false, detail: "diagnostic proxy send: \(String(cString: strerror(errno)))")
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = recv(descriptor, &buffer, buffer.count, 0)
    guard count > 0 else {
      return Result(ok: false, detail: "diagnostic proxy receive: \(String(cString: strerror(errno)))")
    }
    let response = String(decoding: buffer.prefix(count), as: UTF8.self)
    let status = Int(response.split(separator: " ").dropFirst().first ?? "") ?? 0
    return Result(
      ok: status == expectedStatus,
      detail: "diagnostic proxy HTTP \(status), expected \(expectedStatus)"
    )
  }
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
  private var activeAssetDir: String?
  private var activeUplinkHost: String?
  private var tunnelTeardownInFlight = false
  private var lastAppliedExcludedIPv4: [String] = []
  private var reconfigureInFlight = false
  private var reconfigurePendingReason: String?
  private var tunnelLifecycle: TunnelLifecycle?
  private let startTunnelLock = NSLock()
  private var startTunnelInFlight = false

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
      guard uplinkHost?.isEmpty == false else {
        clearStartTunnelInFlight()
        fail("Missing uplink host; refusing unsafe full-tunnel start", code: 11, completionHandler: completionHandler)
        return
      }
      activeUplinkHost = uplinkHost
      tunnelTeardownInFlight = false
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
      let excludedIPv4 = try UplinkIPv4Resolver.resolve(uplinkHost)
      Self.diag(
        "start tunnel: uplinkHost=\(uplinkHost ?? "<none>") "
          + "excludedIPv4=\(excludedIPv4.isEmpty ? "<empty>" : excludedIPv4.joined(separator: ",")) "
          + "session=\(sessionId.isEmpty ? "<none>" : sessionId) source=\(connectSource)")

      self.startLibboxTunnel(
        cfgURL: cfgURL,
        excludedIPv4: excludedIPv4,
        uplinkHost: uplinkHost,
        completionHandler: completionHandler
      )
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

  private func startLibboxTunnel(
    cfgURL: URL,
    excludedIPv4: [String],
    uplinkHost: String?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let configJSON: String
    do {
      let raw = try String(contentsOf: cfgURL, encoding: .utf8)
      configJSON = try Self.configWithMergedUplinkIPs(raw, excludedIPv4: excludedIPv4)
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
        var probeResult = TunnelDataProbe.Result(ok: false, detail: "not-run")
        for attempt in 1 ... 2 {
          if attempt > 1 {
            IOSLibboxCore.stop()
            Thread.sleep(forTimeInterval: 1)
          }
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
          probeResult = TunnelDataProbe.run()
          Self.diag("data probe pre-capture attempt=\(attempt) ok=\(probeResult.ok) detail=\(probeResult.detail)")
          if probeResult.ok {
            try IOSLibboxCore.activateTrafficCapture()
            probeResult = TunnelDataProbe.run()
            Self.diag("data probe captured attempt=\(attempt) ok=\(probeResult.ok) detail=\(probeResult.detail)")
          }
          if probeResult.ok { break }
        }
        guard probeResult.ok else {
          throw NSError(domain: "DemarVpn", code: 46, userInfo: [
            NSLocalizedDescriptionKey: "VPN proxy data path failed: \(probeResult.detail)",
          ])
        }
        Self.diag("libbox service started and data path verified")
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
    clearStartTunnelInFlight()
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
