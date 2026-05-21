import AppIntents
import Foundation
import NetworkExtension
import SwiftUI
import WidgetKit

struct DemarVpnToggleControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(
      kind: VpnControlConstants.kind,
      provider: VpnControlValueProvider()
    ) { isOn in
      ControlWidgetToggle("VPN", isOn: isOn, action: ToggleVpnIntent()) { value in
        Image(systemName: value ? "bolt.shield.fill" : "bolt.slash")
      }
      .tint(.blue)
    }
    .displayName("Demar VPN")
    .description("Быстрое включение и отключение VPN.")
  }
}

struct VpnControlValueProvider: ControlValueProvider {
  let previewValue: Bool = false
  private let tunnelController = VpnTunnelController.shared
  private let opGateKey = "demar_control_intent_gate_until_ms"

  func currentValue() async throws -> Bool {
    if isControlOperationInFlight() {
      switch VpnSharedStore.loadControlState() {
      case "connected", "connecting":
        return true
      default:
        return false
      }
    }
    let status = await withCheckedContinuation { continuation in
      tunnelController.refreshDemarStatus { result in
        switch result {
        case let .success((_, status)):
          continuation.resume(returning: status)
        case .failure:
          continuation.resume(returning: .disconnected)
        }
      }
    }
    switch status {
    case .connected, .connecting, .reasserting:
      return true
    case .disconnected, .disconnecting:
      return false
    case .invalid:
      break
    @unknown default:
      break
    }

    switch VpnSharedStore.loadControlState() {
    case "connecting":
      return true
    default:
      return false
    }
  }

  private func isControlOperationInFlight() -> Bool {
    guard let ud = UserDefaults(suiteName: VpnAppGroup.id) else { return false }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let gate = ud.object(forKey: opGateKey) as? NSNumber
    return (gate?.int64Value ?? 0) > now
  }
}
