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
        .filter { !PhysicalInterfaceSelector.isTunnelInterface($0) }
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
}

/// Monitors network path changes and coordinates in-extension tunnel recovery.
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
  private var pendingRecoveryAfterUnsatisfied = false
  private var unsatisfiedSince: Date?

  private static let pathDebounceInterval: TimeInterval = 2.5
  private static let confirmedPathLossInterval: TimeInterval = 3
  private static let wakeDebounceInterval: TimeInterval = 0.3
  private static let heartbeatInterval: TimeInterval = 15

  init(provider: PacketTunnelProvider) {
    self.provider = provider
  }

  func start(uplinkHost: String?) {
    isStopped = false
    lastPathSignature = nil
    pendingRecoveryAfterUnsatisfied = false
    unsatisfiedSince = nil
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
    pendingRecoveryAfterUnsatisfied = false
    unsatisfiedSince = nil
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
      if self.lastPathSignature == signature { return }
      let note: String
      if let previous = self.lastPathSignature {
        note = "changed \(previous.logLabel) -> \(signature.logLabel)"
      } else {
        note = "initial \(signature.logLabel)"
      }
      #if os(macOS)
      VpnSharedStore.appendJournalLine("[mac] path update: all=\(allIfaces) \(note)")
      #else
      VpnSharedStore.appendJournalLine("[ios] path update: all=\(allIfaces) \(note)")
      #endif
      self.lastPathSignature = signature

      guard path.status == .satisfied else {
        if self.unsatisfiedSince == nil {
          self.unsatisfiedSince = Date()
        }
        self.pendingRecoveryAfterUnsatisfied = true
        return
      }
      // Sticky default-interface reporting keeps naive HTTP/2 on the same uplink across
      // Wi-Fi/cellular flips; only soft-restart after a confirmed path outage.
      guard self.pendingRecoveryAfterUnsatisfied else { return }
      self.pendingRecoveryAfterUnsatisfied = false
      let outage = self.unsatisfiedSince.map { Date().timeIntervalSince($0) } ?? 0
      self.unsatisfiedSince = nil
      guard outage >= Self.confirmedPathLossInterval else {
        #if os(macOS)
        VpnSharedStore.appendJournalLine("[mac] path recovered after short flap: \(String(format: "%.2f", outage))s")
        #else
        VpnSharedStore.appendJournalLine("[ios] path recovered after short flap: \(String(format: "%.2f", outage))s")
        #endif
        return
      }
      self.schedulePathReconfigure(reason: "pathRecoveredAfterLoss")
    }
    pathMonitor.start(queue: monitorQueue)
  }

  private func schedulePathReconfigure(reason: String) {
    pathDebounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.provider?.reconfigureTunnel(reason: reason)
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
