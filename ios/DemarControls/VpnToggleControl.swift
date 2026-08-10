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
    .displayName("Demar Proxy")
    .description(LocalizedStringResource("Quickly turn VPN on or off."))
  }
}

struct VpnControlValueProvider: ControlValueProvider {
  let previewValue: Bool = false
  private let tunnelController = VpnTunnelController.shared

  func currentValue() async throws -> Bool {
    if VpnControlOperationGate.isOperationInFlight() {
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
}
