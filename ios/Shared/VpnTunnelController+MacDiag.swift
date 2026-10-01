import Foundation
import NetworkExtension

extension VpnTunnelController {
#if os(macOS)
  static func logConnectPreflight(cfgURL: URL, assetDir: URL) {
    let fm = FileManager.default
    let cfgSize = (try? fm.attributesOfItem(atPath: cfgURL.path)[.size] as? Int64) ?? -1
    VpnSharedStore.appendPendingUiDiagLine(
      "[vpn] preflight: config=\(cfgSize)B "
        + "geoip=\(CoreBundleAssets.fileSize("geoip.db", in: assetDir))B "
        + "geosite=\(CoreBundleAssets.fileSize("geosite.db", in: assetDir))B "
        + "ads=\(CoreBundleAssets.fileSize(CoreBundleAssets.adsFile, in: assetDir))B"
    )
    let appexExe = Bundle.main.builtInPlugInsURL?
      .appendingPathComponent("DemarPacketTunnel.appex/Contents/MacOS/DemarPacketTunnel")
    let corePath = appexExe?.path ?? "<missing>"
    let coreOK = appexExe.map { fm.isExecutableFile(atPath: $0.path) } ?? false
    VpnSharedStore.appendPendingUiDiagLine(
      "[vpn] preflight: appex=\(coreOK ? "ok" : "missing") path=\(corePath)"
    )
  }

  func scheduleMacOSPostStartProbes(
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

  static func embeddedAppexBundleMismatchDiag() -> String? {
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

  func diagNeSnapshot(_ manager: NETunnelProviderManager, label: String) {
    let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
    let provider = proto?.providerBundleIdentifier ?? "?"
    let desc = manager.localizedDescription ?? "?"
    diag(
      "\(label): ne enabled=\(manager.isEnabled) provider=\(provider) "
        + "status=\(Self.statusLabel(manager.connection.status)) desc=\(desc)"
    )
  }
#endif
}
