import AppIntents
import Foundation
import NetworkExtension
#if canImport(WidgetKit)
import WidgetKit
#endif

struct ToggleVpnIntent: SetValueIntent {
  static let title: LocalizedStringResource = "Toggle VPN"
  static let description = IntentDescription("Enable or disable Demar VPN.")
  static var openAppWhenRun: Bool = false
  static var isDiscoverable: Bool = false

  @Parameter(title: "VPN enabled")
  var value: Bool

  func perform() async throws -> some IntentResult {
    let action = value ? "enable" : "disable"
    VpnSharedStore.appendPendingUiDiagLine("[ui] ios control_center: \(action) requested")
    try await VpnControlExecutor.setVpnEnabled(value)
    await MainActor.run {
      ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
    }
    return .result()
  }
}

private enum VpnControlExecutor {
  private static let tunnelController = VpnTunnelController.shared
  private static let opGateKey = "demar_control_intent_gate_until_ms"
  private static let opGateHoldMs: Int64 = 6000

  static func setVpnEnabled(_ enabled: Bool) async throws {
    if isOperationInFlight() {
      VpnSharedStore.appendPendingUiDiagLine("[ui] ios control_center: ignored (in-flight gate)")
      return
    }
    markOperationInFlight()
    defer { clearOperationGate() }

    let currentStatus = await withCheckedContinuation { continuation in
      tunnelController.currentStatus { status in
        continuation.resume(returning: status)
      }
    }
    if enabled {
      if currentStatus == .connected || currentStatus == .connecting || currentStatus == .reasserting {
        VpnSharedStore.appendPendingUiDiagLine("[ui] ios control_center: enable no-op (already on)")
        return
      }
    } else if currentStatus == .disconnected || currentStatus == .disconnecting || currentStatus == .invalid {
      VpnSharedStore.appendPendingUiDiagLine("[ui] ios control_center: disable no-op (already off)")
      return
    }

    if enabled {
      try await withCheckedThrowingContinuation { continuation in
        tunnelController.connectWithStoredPayload(triggerSource: "controlIntent") { result in
          continuation.resume(with: result)
        }
      }
    } else {
      try await withCheckedThrowingContinuation { continuation in
        tunnelController.disconnect(triggerSource: "controlIntent") { result in
          continuation.resume(with: result)
        }
      }
    }
  }

  private static func isOperationInFlight() -> Bool {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return false }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let gate = ud.object(forKey: opGateKey) as? NSNumber
    return (gate?.int64Value ?? 0) > now
  }

  private static func markOperationInFlight() {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    ud.set(NSNumber(value: now + opGateHoldMs), forKey: opGateKey)
  }

  private static func clearOperationGate() {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return }
    ud.removeObject(forKey: opGateKey)
  }
}
