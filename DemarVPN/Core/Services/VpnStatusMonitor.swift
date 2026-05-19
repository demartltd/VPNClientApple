#if os(iOS)
import Foundation
import NetworkExtension

/// Observes the app's packet-tunnel `NEVPNConnection` and maps status into UI state.
@MainActor
final class VpnStatusMonitor {
    var onStatusChange: ((VpnConnectionState) -> Void)?

    private let controller = VpnTunnelController.shared
    private var connectionObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var lastDeliveredState: VpnConnectionState?
    private weak var trackedConnection: NEVPNConnection?

    func start() {
        refreshStatus(reason: "start")
        startPolling()
    }

    func stop() {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
            self.connectionObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        trackedConnection = nil
    }

    /// Reloads tunnel manager, re-attaches status observer, publishes current status.
    func refreshStatus(reason: String, force: Bool = false) {
        if force {
            lastDeliveredState = nil
        }

        controller.loadTunnelManager { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.retargetObserver(connection: nil)
                    AppLog.shared.append("[vpn] load manager (\(reason)): \(error.localizedDescription)")
                    self.publishResolvedStatus(neStatus: .disconnected, reason: reason)
                case let .success(manager):
                    self.retargetObserver(connection: manager?.connection)
                    let status = manager?.connection.status ?? .disconnected
                    self.publishResolvedStatus(neStatus: status, reason: reason)
                }
            }
        }
    }

    private func retargetObserver(connection: NEVPNConnection?) {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
            self.connectionObserver = nil
        }
        trackedConnection = connection
        guard let connection else { return }

        connectionObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publishResolvedStatus(neStatus: connection.status, reason: "nevpn")
            }
        }
    }

    private func publishResolvedStatus(neStatus: NEVPNStatus, reason: String) {
        let resolved = Self.resolve(neStatus: neStatus, sharedControlState: VpnSharedStore.loadControlState())
        publish(resolved, logReason: reason)
    }

    private func publish(_ state: VpnConnectionState, logReason: String) {
        if lastDeliveredState == state { return }
        lastDeliveredState = state
        VpnSharedStore.saveControlState(Self.controlStateKey(state))
        AppLog.shared.append("[vpn] status (\(logReason)): \(Self.logLabel(state))")
        if case .disconnected = state {
            importPendingDiagnostics()
        }
        onStatusChange?(state)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let connection = self.trackedConnection {
                    self.publishResolvedStatus(neStatus: connection.status, reason: "poll")
                } else {
                    self.refreshStatus(reason: "poll-no-connection")
                }
                self.importPendingDiagnostics()
                self.importXrayTailIfNeeded()
            }
        }
    }

    private func importPendingDiagnostics() {
        for line in VpnSharedStore.drainPendingUiDiagLinesAndClear() where !line.isEmpty {
            AppLog.shared.append(line)
        }
    }

    private func importXrayTailIfNeeded() {
        for line in VpnSharedStore.readIncrementalSharedXrayLogLines() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            AppLog.shared.append("[xray] \(text)")
        }
    }

    /// Merges `NEVPNStatus` with extension-written control state (extension may update first).
    private static func resolve(neStatus: NEVPNStatus, sharedControlState: String?) -> VpnConnectionState {
        let fromNE = map(neStatus)
        guard let shared = sharedControlState?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shared.isEmpty
        else {
            return fromNE
        }

        let fromShared = mapControlState(shared)

        switch (fromNE, fromShared) {
        case (.connected, _), (_, .connected):
            return .connected
        case (.error, _), (_, .error):
            return fromShared
        case (.disconnecting, _), (_, .disconnecting):
            return .disconnecting
        case (.connecting, _), (_, .connecting):
            return .connecting
        default:
            return fromNE
        }
    }

    private static func map(_ status: NEVPNStatus) -> VpnConnectionState {
        switch status {
        case .disconnected:
            return .disconnected
        case .connecting, .reasserting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        case .invalid:
            return .error(message: "VPN configuration invalid.")
        @unknown default:
            return .error(message: "Unknown VPN status.")
        }
    }

    private static func mapControlState(_ raw: String) -> VpnConnectionState {
        switch raw.lowercased() {
        case "connected":
            return .connected
        case "connecting":
            return .connecting
        case "disconnecting":
            return .disconnecting
        case "error":
            return .error(message: "VPN tunnel error.")
        default:
            return .disconnected
        }
    }

    private static func controlStateKey(_ state: VpnConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        case .error: "error"
        }
    }

    private static func logLabel(_ state: VpnConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        case let .error(message): "error (\(message))"
        }
    }
}
#endif
