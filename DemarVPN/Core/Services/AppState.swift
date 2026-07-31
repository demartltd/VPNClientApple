import Foundation
import Observation
#if os(iOS) || os(macOS)
import NetworkExtension
#endif
#if os(iOS)
import WidgetKit
#endif

@MainActor
@Observable
final class AppState {
    private enum StorageKey {
        static let selectedServerId = "selected_server_id"
    }

    let servers: [ServerProfile]
    var selectedServer: ServerProfile?
    var isRefreshingServers = false
    var vpnState: VpnConnectionState = .disconnected
    var downloadBps: Double = 0
    var uploadBps: Double = 0

    var appVersionLabel: String = "1.0.2"
    var appVersionDetailLabel: String {
        "\(appVersionLabel) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))"
    }
    var coreVersionToken: String = BundledCoreVersion.label
    var accountUser: AccountUser?

    private let vpn: VpnControlling
    private var vpnOperationGeneration: UInt64 = 0

    #if os(iOS) || os(macOS)
    private var statusMonitor: VpnStatusMonitor?
    #endif

    init(vpn: VpnControlling? = nil) {
        servers = TestServers.profiles
        selectedServer = Self.restoreSelectedServer(from: servers)
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            appVersionLabel = bundleVersion
        }

        #if os(iOS) || os(macOS)
        self.vpn = vpn ?? NativeVpnService()
        coreVersionToken = BundledCoreVersion.label
        let monitor = VpnStatusMonitor()
        monitor.onStatusChange = { [weak self] state in
            self?.applyRemoteVpnState(state)
        }
        statusMonitor = monitor
        monitor.start()
        #if os(macOS)
        for line in MacVpnDiag.startupLines() {
            AppLog.shared.append("[app] \(line)")
        }
        if case .disabled = MacVpnDiag.pluginkitStatus() {
            AppLog.shared.append("[app] packet-tunnel: disabled — enable Demar VPN in System Settings → Login Items & Extensions → Network Extensions")
        }
        #endif
        #endif
    }

    var canToggleVpn: Bool {
        if case .disconnecting = vpnState { return false }
        return vpnState.isConnected || vpnState == .connecting || selectedServer != nil
    }

    @discardableResult
    private func beginVpnOperation() -> UInt64 {
        vpnOperationGeneration &+= 1
        #if os(iOS) || os(macOS)
        VpnTunnelController.shared.cancelConnectOperation()
        #endif
        return vpnOperationGeneration
    }

    private func isCurrentVpnOperation(_ generation: UInt64) -> Bool {
        generation == vpnOperationGeneration && !Task.isCancelled
    }

    func selectServer(_ server: ServerProfile) {
        selectedServer = server
        Self.persistSelectedServerId(server.id)
        AppLog.shared.append("[ui] server selected: \(server.displayName)")
    }

    func switchServer(to server: ServerProfile) async {
        guard selectedServer?.id != server.id else { return }
        #if os(iOS) || os(macOS)
        let neStatus = await withCheckedContinuation { (continuation: CheckedContinuation<NEVPNStatus, Never>) in
            VpnTunnelController.shared.currentStatus { continuation.resume(returning: $0) }
        }
        let neActive = neStatus == .connected || neStatus == .connecting || neStatus == .reasserting
        #else
        let neActive = false
        #endif
        let shouldReconnect = vpnState.isConnected || vpnState.isBusy || vpnState.hasError || neActive
        selectServer(server)
        guard shouldReconnect else { return }

        let generation = beginVpnOperation()
        statusMonitor?.endConnectAttempt()
        vpnState = .disconnecting
        resetThroughput()
        do {
            try await vpn.disconnect()
            let idle = await waitUntilSystemDisconnected(timeoutSeconds: 10)
            guard isCurrentVpnOperation(generation) else { return }
            if !idle {
                AppLog.shared.append("[vpn] switch: NE still busy after disconnect wait")
            }
            vpnState = .disconnected
            await connect(force: true, operationGeneration: generation)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentVpnOperation(generation) else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vpnState = .error(message: message)
            AppLog.shared.append("[vpn] server switch failed: \(message)")
        }
    }

    @discardableResult
    func signIn(email: String, password: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), !password.isEmpty else { return false }
        let name = trimmed.split(separator: "@").first.map(String.init) ?? trimmed
        accountUser = AccountUser(email: trimmed, displayName: name.capitalized)
        AppLog.shared.append("[ui] account sign-in: \(trimmed)")
        return true
    }

    func signOut() {
        guard let email = accountUser?.email else { return }
        accountUser = nil
        AppLog.shared.append("[ui] account sign-out: \(email)")
    }

    func connect() async {
        let generation = beginVpnOperation()
        let force: Bool
        if case .error = vpnState { force = true }
        else { force = false }
        await connect(force: force, operationGeneration: generation)
    }

    private func connect(force: Bool, operationGeneration: UInt64) async {
        guard let server = selectedServer else { return }
        #if os(iOS) || os(macOS)
        let systemStatus = await withCheckedContinuation { (continuation: CheckedContinuation<NEVPNStatus, Never>) in
            VpnTunnelController.shared.currentStatus { status in
                continuation.resume(returning: status)
            }
        }
        guard isCurrentVpnOperation(operationGeneration) else { return }
        if !force, systemStatus == .connected || systemStatus == .connecting || systemStatus == .reasserting {
            AppLog.shared.append("[ui] connect ignored: system tunnel already active (\(systemStatus.rawValue))")
            statusMonitor?.refreshStatus(reason: "connect-noop", force: true, reloadPreferences: false)
            return
        }
        if force, systemStatus == .connected || systemStatus == .connecting || systemStatus == .reasserting {
            AppLog.shared.append("[ui] connect force: stopping leftover NE status=\(systemStatus.rawValue)")
            try? await vpn.disconnect()
            _ = await waitUntilSystemDisconnected(timeoutSeconds: 8)
            guard isCurrentVpnOperation(operationGeneration) else { return }
        }
        #endif
        if !force, vpnState.isConnected {
            AppLog.shared.append("[ui] connect ignored: already connected")
            statusMonitor?.refreshStatus(reason: "connect-noop-ui", force: true, reloadPreferences: false)
            return
        }
        if case .connecting = vpnState, !force { return }
        guard force || !vpnState.isBusy else { return }

        if case .disconnected = vpnState {
            vpnState = .connecting
            resetThroughput()
        } else if force {
            vpnState = .connecting
            resetThroughput()
        }
        AppLog.shared.append("[ui] connect → \(server.displayName)")

        #if os(macOS)
        if let block = MacVpnDiag.connectBlockReason() {
            if MacVpnDiag.pluginkitStatus().shouldOpenSystemSettings {
                MacVpnDiag.openNetworkExtensionsSettings()
            }
            vpnState = .error(message: block)
            AppLog.shared.append("[vpn] connect blocked: \(block)")
            return
        }
        if MacVpnDiag.consumeVPNProfileResetFlag() {
            AppLog.shared.append("[vpn] host bundle changed — resetting VPN profile")
            await resetDemarVPNProfileForNewHostBundle()
        }
        #endif

        statusMonitor?.beginConnectAttempt()
        do {
            try await vpn.connect(server: server)
            guard isCurrentVpnOperation(operationGeneration) else { return }
            for line in VpnSharedStore.drainPendingUiDiagLinesAndClear() where !line.isEmpty {
                AppLog.shared.append(line)
            }
            statusMonitor?.refreshStatus(reason: "connect", force: true, reloadPreferences: false)
        } catch is CancellationError {
            statusMonitor?.endConnectAttempt()
            return
        } catch {
            statusMonitor?.endConnectAttempt()
            guard isCurrentVpnOperation(operationGeneration) else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vpnState = .error(message: message)
            AppLog.shared.append("[vpn] connect failed: \(message)")
        }
    }

    func disconnect() async {
        let generation = beginVpnOperation()
        if case .disconnecting = vpnState { return }

        if vpnState.isConnected || vpnState == .connecting {
            vpnState = .disconnecting
            resetThroughput()
        }
        AppLog.shared.append("[ui] disconnect")
        statusMonitor?.endConnectAttempt()

        do {
            try await vpn.disconnect()
            _ = await waitUntilSystemDisconnected(timeoutSeconds: 8)
            guard isCurrentVpnOperation(generation) else { return }
            statusMonitor?.refreshStatus(reason: "disconnect", force: true)
        } catch {
            guard isCurrentVpnOperation(generation) else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vpnState = .error(message: message)
            AppLog.shared.append("[vpn] disconnect failed: \(message)")
        }
    }

    func toggleVpn() async {
        if vpnState.isConnected || vpnState == .connecting {
            await disconnect()
        } else {
            await connect()
        }
    }

    #if os(iOS) || os(macOS)
    private func waitUntilSystemDisconnected(timeoutSeconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            VpnTunnelController.shared.waitUntilDisconnected(timeout: timeoutSeconds) { idle in
                continuation.resume(returning: idle)
            }
        }
    }
    #endif

    /// Claims the refresh lock. Returns false if a refresh is already running.
    func beginServersRefresh() -> Bool {
        guard !isRefreshingServers else { return false }
        isRefreshingServers = true
        return true
    }

    /// Finishes a refresh started with `beginServersRefresh()`.
    func endServersRefresh(minimumVisibleDuration: Duration = .zero) async -> Bool {
        defer { isRefreshingServers = false }
        if minimumVisibleDuration > .zero {
            try? await Task.sleep(for: minimumVisibleDuration)
        }
        return !Task.isCancelled
    }

    #if os(macOS)
    private func resetDemarVPNProfileForNewHostBundle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            VpnTunnelController.shared.removeAllDemarVPNProfiles {
                continuation.resume()
            }
        }
    }
    #endif

    #if os(iOS) || os(macOS)
    func syncVpnStatusFromSystem() {
        statusMonitor?.importForegroundDiagnostics()
        statusMonitor?.refreshStatus(reason: "sync", force: true, reloadPreferences: false)
        #if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
        #endif
    }

    private func applyRemoteVpnState(_ state: VpnConnectionState) {
        vpnState = state
        if !state.isConnected { resetThroughput() }
    }

    private func resetThroughput() {
        downloadBps = 0
        uploadBps = 0
    }

    private static func restoreSelectedServer(from servers: [ServerProfile]) -> ServerProfile? {
        guard let savedId = UserDefaults.standard.string(forKey: StorageKey.selectedServerId) else {
            return servers.first
        }
        return servers.first(where: { $0.id == savedId }) ?? servers.first
    }

    private static func persistSelectedServerId(_ id: String) {
        UserDefaults.standard.set(id, forKey: StorageKey.selectedServerId)
    }

    #if os(iOS) || os(macOS)
    func runHomeThroughputSampling() async {
        while !Task.isCancelled {
            if vpnState.isConnected, let t = VpnSharedStore.readThroughput() {
                downloadBps = Double(t.down)
                uploadBps = Double(t.up)
            } else {
                resetThroughput()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    #endif
    #endif
}
