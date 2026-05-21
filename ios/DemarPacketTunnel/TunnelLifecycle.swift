#if os(iOS)
import Foundation
import Network
import NetworkExtension

/// Physical network path signature — ignores VPN/tunnel interfaces to avoid feedback loops.
struct TunnelPathSignature: Equatable {
  let status: Network.NWPath.Status
  let physicalInterfaces: Set<String>
  let usesWifi: Bool
  let usesCellular: Bool
  let isExpensive: Bool
  let isConstrained: Bool

  static func from(path: Network.NWPath) -> TunnelPathSignature {
    let physical = Set(
      path.availableInterfaces
        .map { $0.name }
        .filter { !Self.isTunnelInterface($0) }
    )
    return TunnelPathSignature(
      status: path.status,
      physicalInterfaces: physical,
      usesWifi: path.usesInterfaceType(.wifi),
      usesCellular: path.usesInterfaceType(.cellular),
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained
    )
  }

  var logLabel: String {
    let ifaces = physicalInterfaces.sorted().joined(separator: ",")
    let status = status == .satisfied ? "satisfied" : String(describing: status)
    return "status=\(status) phys=\(ifaces.isEmpty ? "<none>" : ifaces) "
      + "wifi=\(usesWifi) cell=\(usesCellular) expensive=\(isExpensive) constrained=\(isConstrained)"
  }

  private static func isTunnelInterface(_ name: String) -> Bool {
    let n = name.lowercased()
    if n == "lo0" { return true }
    if n.hasPrefix("utun") { return true }
    if n.hasPrefix("ipsec") { return true }
    if n.hasPrefix("ppp") { return true }
    return false
  }
}

/// Monitors network path changes and coordinates in-extension tunnel recovery (iOS).
final class TunnelLifecycle {
  private weak var provider: PacketTunnelProvider?
  private let pathMonitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "vpn.demar.path", qos: .utility)
  private var pathDebounceWork: DispatchWorkItem?
  private var wakeDebounceWork: DispatchWorkItem?
  private var heartbeatTimer: DispatchSourceTimer?
  private var uplinkHost: String?
  private var isStopped = false
  private var lastPathSignature: TunnelPathSignature?

  private static let pathDebounceInterval: TimeInterval = 1.5
  private static let wakeDebounceInterval: TimeInterval = 0.3
  private static let heartbeatInterval: TimeInterval = 45

  init(provider: PacketTunnelProvider) {
    self.provider = provider
  }

  func start(uplinkHost: String?) {
    isStopped = false
    lastPathSignature = nil
    self.uplinkHost = uplinkHost?.trimmingCharacters(in: .whitespacesAndNewlines)
    startPathMonitor()
    startRunningHeartbeat()
  }

  func stop() {
    isStopped = true
    pathDebounceWork?.cancel()
    pathDebounceWork = nil
    wakeDebounceWork?.cancel()
    wakeDebounceWork = nil
    lastPathSignature = nil
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
    pathMonitor.cancel()
  }

  func scheduleRevalidate(reason: String) {
    guard !isStopped else { return }
    wakeDebounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.provider?.reconfigureTunnel(reason: reason)
    }
    wakeDebounceWork = work
    monitorQueue.asyncAfter(deadline: .now() + Self.wakeDebounceInterval, execute: work)
  }

  private func startPathMonitor() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard let self, !self.isStopped else { return }
      let allIfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
      let signature = TunnelPathSignature.from(path: path)
      let note: String
      if let previous = self.lastPathSignature {
        if signature == previous {
          note = "unchanged"
        } else {
          note = "changed \(previous.logLabel) -> \(signature.logLabel)"
        }
      } else {
        note = "initial \(signature.logLabel)"
      }
      VpnSharedStore.appendJournalLine(
        "[ios] path update: all=\(allIfaces) \(note)"
      )

      guard path.status == .satisfied else {
        self.lastPathSignature = signature
        return
      }

      if let previous = self.lastPathSignature, signature == previous {
        return
      }
      self.lastPathSignature = signature
      self.schedulePathReconfigure()
    }
    pathMonitor.start(queue: monitorQueue)
  }

  private func schedulePathReconfigure() {
    pathDebounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.provider?.reconfigureTunnel(reason: "pathChange")
    }
    pathDebounceWork = work
    monitorQueue.asyncAfter(deadline: .now() + Self.pathDebounceInterval, execute: work)
  }

  private func startRunningHeartbeat() {
    heartbeatTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
    timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
    timer.setEventHandler {
      VpnSharedStore.saveExtensionHeartbeat(phase: "running")
    }
    timer.resume()
    heartbeatTimer = timer
    VpnSharedStore.saveExtensionHeartbeat(phase: "running")
  }
}
#endif
