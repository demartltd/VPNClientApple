import Darwin
import Foundation
import NetworkExtension
#if canImport(WidgetKit)
import WidgetKit
#endif

#if canImport(DemarXray)
import DemarXray
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

  private let xrayQueue = DispatchQueue(label: "vpn.demar.xray", qos: .userInitiated)
  private static let controlKind = "com.demar.vpn.controls.vpn-toggle"
  private static let providerKeySessionId = "vpnSessionId"
  private static let providerKeyConnectSource = "connectTriggerSource"
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
  private var macXrayChild: MacXrayChild?
  private let startTunnelLock = NSLock()
  private var startTunnelInFlight = false
  #endif

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    _ = TunnelBootstrap.once
    #if os(macOS)
    startTunnelLock.lock()
    if startTunnelInFlight {
      startTunnelLock.unlock()
      Self.diag("startTunnel ignored: already in flight")
      completionHandler(nil)
      return
    }
    startTunnelInFlight = true
    startTunnelLock.unlock()
    #endif
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
        Self.fail("Missing shared config.json", code: 2, completionHandler: completionHandler)
        return
      }

      let optionUplinkHost = (options?["uplinkHost"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let configuredUplinkHost =
        ((protocolConfiguration as? NETunnelProviderProtocol)?
          .providerConfiguration?["uplinkHost"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let optionSessionId = (options?[Self.providerKeySessionId] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let configuredSessionId =
        ((protocolConfiguration as? NETunnelProviderProtocol)?
          .providerConfiguration?[Self.providerKeySessionId] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let sessionId = (optionSessionId?.isEmpty == false ? optionSessionId : configuredSessionId) ?? ""
      let optionSource = (options?[Self.providerKeyConnectSource] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let configuredSource =
        ((protocolConfiguration as? NETunnelProviderProtocol)?
          .providerConfiguration?[Self.providerKeyConnectSource] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let connectSource = (optionSource?.isEmpty == false ? optionSource : configuredSource) ?? "unknown"
      let uplinkHost = (optionUplinkHost?.isEmpty == false ? optionUplinkHost : configuredUplinkHost)
      #if os(iOS)
      activeUplinkHost = uplinkHost
      tunnelTeardownInFlight = false
      lastAppliedExcludedIPv4 = []
      reconfigureInFlight = false
      reconfigurePendingReason = nil
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

      let settings = Self.buildTunnelSettings(excludedIPv4: excludedIPv4)

      setTunnelNetworkSettings(settings) { [weak self] error in
        guard let self else {
          Self.fail("Tunnel released before completion.", code: 5, completionHandler: completionHandler)
          return
        }
        if let error {
          self.clearStartTunnelInFlight()
          Self.fail(
            "setTunnelNetworkSettings failed: \(error.localizedDescription)",
            code: 7,
            completionHandler: completionHandler
          )
          return
        }
        VpnSharedStore.saveExtensionHeartbeat(phase: "setTunnelNetworkSettings-ok")

        guard let selectedTun = Self.resolveTunnelAfterSettings() else {
          self.clearStartTunnelInFlight()
          Self.fail("Could not locate utun file descriptor.", code: 3, completionHandler: completionHandler)
          return
        }

        let tunFd = selectedTun.fd
        let ifaceName = selectedTun.name
        guard ifaceName.hasPrefix("utun"), Self.interfaceName(forUtunFd: tunFd) == ifaceName else {
          self.clearStartTunnelInFlight()
          Self.fail(
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
          Self.fail(
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
            "xray assets: \(Self.assetFileDescription(named: "geoip.dat", in: assetDirURL)), "
              + "\(Self.assetFileDescription(named: "geosite.dat", in: assetDirURL))")
        } catch {
          self.clearStartTunnelInFlight()
          Self.fail(
            "asset directory lookup failed: \(error.localizedDescription)",
            code: 12,
            completionHandler: completionHandler
          )
          return
        }

        self.xrayQueue.async {
          #if os(macOS)
          VpnSharedStore.saveExtensionHeartbeat(phase: "xray-starting")
          do {
            let child = try MacXrayProcess.start(configPath: cfgURL.path, tunFd: tunFd, assetDir: assetDir)
            self.macXrayChild = child
            Self.diag("xray subprocess started (pid=\(child.pid))")
            VpnSharedStore.saveExtensionHeartbeat(phase: "xray-started")
            self.tunnelStartedAt = Date()
            VpnSharedStore.saveControlState("connected")
            Self.reloadControls()
            self.clearStartTunnelInFlight()
            DispatchQueue.main.async { completionHandler(nil) }
          } catch {
            VpnSharedStore.saveExtensionHeartbeat(phase: "xray-failed")
            self.clearStartTunnelInFlight()
            Self.fail(
              "xray start error: \(error.localizedDescription)",
              code: 22,
              completionHandler: completionHandler
            )
          }
          #else
          var err: NSError?
          let ok = DemarxrayStart(cfgURL.path, tunFd, assetDir, &err)
          if !ok {
            let out = err ?? NSError(
              domain: "DemarVpn",
              code: 6,
              userInfo: [NSLocalizedDescriptionKey: "Xray failed to start (unknown error)."]
            )
            logLine("xray start error: \(out.localizedDescription)")
            Self.diag("xray start error: \(out.localizedDescription)")
            VpnSharedStore.saveControlState("error")
            Self.reloadControls()
            DispatchQueue.main.async { completionHandler(out) }
            return
          }
          Self.diag("xray started successfully")
          self.tunnelStartedAt = Date()
          self.activeTunFd = tunFd
          self.activeIfaceName = ifaceName
          self.activeAssetDir = assetDir
          self.lastAppliedExcludedIPv4 = excludedIPv4.sorted()
          VpnSharedStore.saveExtensionHeartbeat(phase: "xray-started")
          VpnSharedStore.saveControlState("connected")
          Self.reloadControls()
          self.tunnelLifecycle?.stop()
          self.tunnelLifecycle = TunnelLifecycle(provider: self)
          self.tunnelLifecycle?.start(uplinkHost: uplinkHost)
          DispatchQueue.main.async { completionHandler(nil) }
          #endif
        }
      }
    } catch {
      clearStartTunnelInFlight()
      Self.fail(error.localizedDescription, code: 1, completionHandler: completionHandler)
    }
  }

  private func clearStartTunnelInFlight() {
    #if os(macOS)
    startTunnelLock.lock()
    startTunnelInFlight = false
    startTunnelLock.unlock()
    #endif
  }

  #if os(iOS)
  override func sleep(completionHandler: @escaping () -> Void) {
    appendDiagLine("device sleep (disconnectOnSleep=false, tunnel stays up)")
    completionHandler()
  }

  override func wake() {
    appendDiagLine("device wake")
    tunnelLifecycle?.scheduleRevalidate(reason: "wake")
  }

  /// Re-applies routes and restarts xray after network path change or wake (extension-only).
  func reconfigureTunnel(reason: String) {
    guard !tunnelTeardownInFlight else { return }
    guard activeTunFd != nil, activeAssetDir != nil else { return }

    xrayQueue.async { [weak self] in
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
    guard let tunFd = activeTunFd, let assetDir = activeAssetDir else {
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
      Self.diag("reconfigure(\(reason)) skipped: routes unchanged")
      finishReconfigureCoalesced()
      return
    }

    let settings = Self.buildTunnelSettings(excludedIPv4: excluded)
    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      self.xrayQueue.async {
        guard !self.tunnelTeardownInFlight else {
          self.finishReconfigureCoalesced()
          return
        }
        if let error {
          Self.diag("reconfigure(\(reason)) setTunnelNetworkSettings failed: \(error.localizedDescription)")
          self.finishReconfigureCoalesced()
          return
        }
        self.lastAppliedExcludedIPv4 = excluded
        DemarxrayStop()
        var err: NSError?
        let ok = DemarxrayStart(cfgPath, tunFd, assetDir, &err)
        if !ok {
          let msg = err?.localizedDescription ?? "unknown"
          Self.diag("reconfigure(\(reason)) xray restart failed: \(msg)")
          self.finishReconfigureCoalesced()
          return
        }
        VpnSharedStore.saveExtensionHeartbeat(phase: "running")
        Self.diag(
          "reconfigure(\(reason)) ok excluded=\(excluded.isEmpty ? "<empty>" : excluded.joined(separator: ","))"
        )
        self.finishReconfigureCoalesced()
      }
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
    if reason == .providerFailed, let lastXray = VpnSharedStore.readLastXrayErrorLineSnapshot() {
      appendDiagLine("tunnel stop providerFailed: xray_last_error=\(lastXray)")
    }
    xrayQueue.async {
      #if os(macOS)
      MacXrayProcess.stop(self.macXrayChild)
      self.macXrayChild = nil
      self.clearStartTunnelInFlight()
      VpnSharedStore.clearExtensionHeartbeat()
      #else
      DemarxrayStop()
      VpnSharedStore.clearExtensionHeartbeat()
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

  private static func reloadControls() {
#if canImport(WidgetKit) && os(iOS)
    DispatchQueue.main.async {
      ControlCenter.shared.reloadControls(ofKind: Self.controlKind)
    }
#endif
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
      return "advice=inspect xray-ios error log for fatal core error"
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
    guard let host, !host.isEmpty else { return [] }
    if Self.isIPv4(host) {
      return [host]
    }

    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_INET,
      ai_socktype: SOCK_STREAM,
      ai_protocol: 0,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )

    var info: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, nil, &hints, &info)
    guard rc == 0, let start = info else {
      throw NSError(domain: "DemarVpn", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "DNS resolve failed for uplink host \(host): \(String(cString: gai_strerror(rc)))",
      ])
    }
    defer { freeaddrinfo(start) }

    var results: [String] = []
    var ptr: UnsafeMutablePointer<addrinfo>? = start
    while let p = ptr {
      var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let gaRet = getnameinfo(
        p.pointee.ai_addr,
        p.pointee.ai_addrlen,
        &hostBuf,
        socklen_t(hostBuf.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if gaRet == 0 {
        results.append(String(cString: hostBuf))
      }
      ptr = p.pointee.ai_next
    }

    return Array(Set(results))
  }

  private static func isIPv4(_ s: String) -> Bool {
    var addr = in_addr()
    return s.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
  }

  private static let sysprotoControl: Int32 = 2
  private static let utunOptIfName: Int32 = 2

  /// Call only after setTunnelNetworkSettings succeeds.
  private static func resolveTunnelAfterSettings() -> (fd: Int64, name: String)? {
    #if os(macOS)
    // Do not use tunnelFileDescriptorViaControl(): it returns a utun_control socket,
    // not the packet I/O fd Xray needs (causes "bad file descriptor" on start).
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

  /// Fallback: scan fds (Xray `proxy/tun/README.md` iOS loop).
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
        NSLocalizedDescriptionKey: "Invalid Xray JSON (expected object with inbounds[]).",
      ])
    }

    var patched = false
    for i in 0..<inbounds.count {
      guard let proto = inbounds[i]["protocol"] as? String, proto == "tun" else { continue }
      guard var settings = inbounds[i]["settings"] as? [String: Any] else { continue }
      settings["name"] = interfaceName
      inbounds[i]["settings"] = settings
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

  private static func fail(
    _ message: String,
    code: Int,
    completionHandler: @escaping (Error?) -> Void
  ) {
    VpnSharedStore.saveControlState("error")
    VpnSharedStore.saveExtensionHeartbeat(phase: "failed-\(code)")
    reloadControls()
    diag(message)
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
