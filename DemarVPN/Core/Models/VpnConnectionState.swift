import Foundation

enum VpnConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }

    var hasError: Bool {
        if case .error = self { return true }
        return false
    }
}
