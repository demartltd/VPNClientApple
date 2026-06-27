import Foundation

/// Default-interface state reported to the sing-box core.
struct DefaultInterfaceUpdate: Equatable {
  static let lost = DefaultInterfaceUpdate(name: "", index: -1, isExpensive: false, isConstrained: false)

  var name: String
  var index: Int32
  var isExpensive: Bool
  var isConstrained: Bool

  var isLost: Bool { index < 0 }
}

enum PhysicalInterfaceKind: Equatable {
  case wifi
  case cellular
  case ethernet
  case other
}

struct PhysicalInterfaceCandidate: Equatable {
  var name: String
  var index: Int32
  var kind: PhysicalInterfaceKind
}

enum PhysicalInterfaceSelector {
  static func isTunnelInterface(_ name: String) -> Bool {
    let n = name.lowercased()
    return n == "lo0" || n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp")
  }

  static func preferred(
    from interfaces: [PhysicalInterfaceCandidate],
    usesWifi: Bool,
    usesCellular: Bool,
    usesEthernet: Bool
  ) -> PhysicalInterfaceCandidate? {
    if usesWifi, let item = interfaces.first(where: { $0.kind == .wifi }) { return item }
    if usesCellular, let item = interfaces.first(where: { $0.kind == .cellular }) { return item }
    if usesEthernet, let item = interfaces.first(where: { $0.kind == .ethernet }) { return item }
    return interfaces.first
  }
}

/// Filters default-interface updates before they reach libbox: duplicates are
/// dropped and interface loss is debounced. Libbox v1.13.14 closes every
/// connection as soon as it sees an empty default interface, so the transient
/// `unsatisfied` flaps NWPathMonitor emits inside a Network Extension
/// (routes/DNS apply, Wi-Fi scan, sleep/wake) must never be forwarded raw.
final class DefaultInterfaceReportFilter {
  enum Decision: Equatable {
    case report(DefaultInterfaceUpdate)
    case scheduleLoss
    case ignore
  }

  private(set) var lastReported: DefaultInterfaceUpdate?
  private var lossPending = false

  func decide(_ update: DefaultInterfaceUpdate) -> Decision {
    guard !update.isLost else {
      guard lastReported?.isLost != true, !lossPending else { return .ignore }
      lossPending = true
      return .scheduleLoss
    }
    lossPending = false
    guard update != lastReported else { return .ignore }
    lastReported = update
    return .report(update)
  }

  /// Called when the loss debounce fires; returns the loss to report unless the path recovered meanwhile.
  func confirmLoss() -> DefaultInterfaceUpdate? {
    guard lossPending else { return nil }
    lossPending = false
    lastReported = .lost
    return .lost
  }

  func reset() {
    lastReported = nil
    lossPending = false
  }
}
