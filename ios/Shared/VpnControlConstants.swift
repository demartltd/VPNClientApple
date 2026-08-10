import Foundation
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

enum VpnControlConstants {
  static let kind = "com.demar.adblock.controls.vpn-toggle"
}

enum VpnTunnelProviderKeys {
  static let uplinkHost = "uplinkHost"
  static let sessionId = "vpnSessionId"
  static let connectSource = "connectTriggerSource"
}

enum VpnControlOperationGate {
  private static let opGateKey = "demar_control_intent_gate_until_ms"
  private static let opGateHoldMs: Int64 = 6000

  static func isOperationInFlight() -> Bool {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return false }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let gate = ud.object(forKey: opGateKey) as? NSNumber
    return (gate?.int64Value ?? 0) > now
  }

  static func markOperationInFlight() {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    ud.set(NSNumber(value: now + opGateHoldMs), forKey: opGateKey)
  }

  static func clearOperationGate() {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return }
    ud.removeObject(forKey: opGateKey)
  }
}

enum VpnControlReloader {
  private static let lock = NSLock()
  private static var pendingWork: DispatchWorkItem?

  static func reloadControls() {
#if canImport(WidgetKit) && os(iOS)
    lock.lock()
    pendingWork?.cancel()
    let work = DispatchWorkItem {
      ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
    }
    pendingWork = work
    lock.unlock()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
#endif
  }
}
