import Foundation

enum VpnTunnelError: LocalizedError {
  case missingPayload
  case missingAssets
  case missingUplinkHost
  case managerDisabled
  case connectInProgress
  case noProviderSession
  case appexBundleMismatch
  case openFluxHostRequired

  var errorDescription: String? {
    switch self {
    case .missingPayload:
      return String(localized: "Open the Demar Proxy app once for initial setup.")
    case .missingAssets:
      return String(localized: "Core assets are missing.")
    case .missingUplinkHost:
      return String(localized: "Couldn’t resolve uplinkHost for the VPN route exclusion.")
    case .managerDisabled:
      return String(localized: "VPN profile is disabled in the system. Enable Demar Proxy in System Settings → VPN.")
    case .connectInProgress:
      return String(localized: "A connection is already in progress.")
    case .noProviderSession:
      return String(localized: "Couldn’t open a VPN session (NETunnelProviderSession). Reinstall the VPN profile in system settings.")
    case .appexBundleMismatch:
      return String(localized: "The embedded DemarPacketTunnel extension is damaged or missing. Reinstall the app.")
    case .openFluxHostRequired:
      return String(localized: "Open Demar Proxy to connect White List VPN.")
    }
  }
}
