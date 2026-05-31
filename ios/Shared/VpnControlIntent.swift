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
    VpnControlReloader.reloadControls()
    return .result()
  }
}

private enum VpnControlExecutor {
  private static let tunnelController = VpnTunnelController.shared

  static func setVpnEnabled(_ enabled: Bool) async throws {
    if VpnControlOperationGate.isOperationInFlight() {
      VpnSharedStore.appendPendingUiDiagLine("[ui] ios control_center: ignored (in-flight gate)")
      return
    }
    VpnControlOperationGate.markOperationInFlight()
    defer { VpnControlOperationGate.clearOperationGate() }

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

}
