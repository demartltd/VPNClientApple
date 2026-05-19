import Darwin
import Foundation
import NetworkExtension
#if canImport(WidgetKit)
import WidgetKit
#endif

import DemarXray

private func logLine(_ message: String) {
  NSLog("[DemarPacketTunnel] %@", message)
}

private func appendDiagLine(_ message: String) {
  VpnSharedStore.appendPendingUiDiagLine("[ios] \(message)")
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

  private let xrayQueue = DispatchQueue(label: "vpn.demar.xray", qos: .userInitiated)
  private static let controlKind = "com.demar.vpn.controls.vpn-toggle"
  private static let providerKeySessionId = "vpnSessionId"
  private static let providerKeyConnectSource = "connectTriggerSource"
  private var currentSessionId: String?
  private var tunnelStartedAt: Date?

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    VpnSharedStore.saveControlState("connecting")
    Self.reloadControls()
    do {
      let cfgURL = try VpnAppGroup.configURL()
      guard FileManager.default.fileExists(atPath: cfgURL.path) else {
        VpnSharedStore.saveControlState("error")
        Self.reloadControls()
        completionHandler(NSError(domain: "DemarVpn", code: 2, userInfo: [
          NSLocalizedDescriptionKey: "Missing shared config.json",
        ]))
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
          completionHandler(NSError(domain: "DemarVpn", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Tunnel released before completion.",
          ]))
          return
        }
        if let error {
          Self.diag("setTunnelNetworkSettings failed: \(error.localizedDescription)")
          VpnSharedStore.saveControlState("error")
          Self.reloadControls()
          completionHandler(error)
          return
        }

        guard let selectedTun = Self.selectUtunCandidate() else {
          Self.diag("utun discovery failed: no candidate interfaces")
          VpnSharedStore.saveControlState("error")
          Self.reloadControls()
          completionHandler(NSError(domain: "DemarVpn", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate utun file descriptor.",
          ]))
          return
        }

        let tunFd = selectedTun.fd
        let ifaceName = selectedTun.name
        guard ifaceName.hasPrefix("utun"), Self.interfaceName(forUtunFd: tunFd) == ifaceName else {
          Self.diag("utun validation failed: fd=\(tunFd) interface=\(ifaceName)")
          VpnSharedStore.saveControlState("error")
          Self.reloadControls()
          completionHandler(NSError(domain: "DemarVpn", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Could not read utun interface name.",
          ]))
          return
        }
        Self.diag("utun selected: fd=\(tunFd) interface=\(ifaceName)")

        do {
          try Self.patchTunInboundName(at: cfgURL, interfaceName: ifaceName)
          Self.diag("patched tun inbound name: \(ifaceName)")
        } catch {
          Self.diag("patchTunInboundName failed: \(error.localizedDescription)")
          VpnSharedStore.saveControlState("error")
          Self.reloadControls()
          completionHandler(error)
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
          Self.diag("asset directory lookup failed: \(error.localizedDescription)")
          VpnSharedStore.saveControlState("error")
          Self.reloadControls()
          completionHandler(error)
          return
        }

        self.xrayQueue.async {
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
            DispatchQueue.main.async {
              completionHandler(out)
            }
            return
          }
          Self.diag("xray started successfully")
          self.tunnelStartedAt = Date()
          VpnSharedStore.saveControlState("connected")
          Self.reloadControls()
          DispatchQueue.main.async {
            completionHandler(nil)
          }
        }
      }
    } catch {
      VpnSharedStore.saveControlState("error")
      Self.reloadControls()
      completionHandler(error)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
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
      "tunnel stop: \(reasonLabel) raw=\(reason.rawValue) source=\(triggerSource ?? "unknown") "
        + "session=\(sessionId ?? "<none>") \(advice)"
    )
    if reason == .providerFailed, let lastXray = VpnSharedStore.readLastXrayErrorLineSnapshot() {
      appendDiagLine("tunnel stop providerFailed: xray_last_error=\(lastXray)")
    }
    xrayQueue.async {
      DemarxrayStop()
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
#if canImport(WidgetKit)
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

  /// Matches the discovery loop documented in Xray `proxy/tun/README.md` for iOS NetworkExtension.
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
    let candidates = findUtunCandidates()
      .filter { $0.name.hasPrefix("utun") }
    if candidates.isEmpty {
      return nil
    }
    // Highest fd is typically the most recently created socket for this extension instance.
    return candidates.max(by: { $0.fd < $1.fd })
  }

  private static func interfaceName(forUtunFd fd: Int64) -> String? {
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    var len = socklen_t(buf.count)
    guard getsockopt(Int32(fd), 2, 2, &buf, &len) == 0 else {
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
}
