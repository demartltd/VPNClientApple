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
    let servers: [ServerProfile]
    var selectedServer: ServerProfile?
    var vpnState: VpnConnectionState = .disconnected
    var downloadBps: Double = 0
    var uploadBps: Double = 0

    var appVersionLabel: String = "1.0.2"
    var coreVersionToken: String = BundledCoreVersion.label
    var accountUser: AccountUser?

    private let vpn: VpnControlling

    #if os(iOS) || os(macOS)
    private var statusMonitor: VpnStatusMonitor?
    #endif
    #if os(iOS) || os(macOS)
    private var throughputBaseline: (rx: UInt64, tx: UInt64, at: Date)?
    private var throughputSampling = false
    #endif

    init(vpn: VpnControlling? = nil) {
        servers = TestServers.profiles
        selectedServer = servers.first
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
        !vpnState.isBusy && (vpnState.isConnected || selectedServer != nil)
    }

    func selectServer(_ server: ServerProfile) {
        selectedServer = server
        AppLog.shared.append("[ui] server selected: \(server.displayName)")
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
        guard let server = selectedServer else { return }
        #if os(iOS) || os(macOS)
        let systemStatus = await withCheckedContinuation { (continuation: CheckedContinuation<NEVPNStatus, Never>) in
            VpnTunnelController.shared.currentStatus { status in
                continuation.resume(returning: status)
            }
        }
        if systemStatus == .connected || systemStatus == .connecting || systemStatus == .reasserting {
            AppLog.shared.append("[ui] connect ignored: system tunnel already active (\(systemStatus.rawValue))")
            statusMonitor?.refreshStatus(reason: "connect-noop", force: true, reloadPreferences: false)
            return
        }
        #endif
        if vpnState.isConnected {
            AppLog.shared.append("[ui] connect ignored: already connected")
            statusMonitor?.refreshStatus(reason: "connect-noop-ui", force: true, reloadPreferences: false)
            return
        }
        if case .connecting = vpnState { return }
        guard !vpnState.isBusy else { return }

        if case .disconnected = vpnState {
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
            for line in VpnSharedStore.drainPendingUiDiagLinesAndClear() where !line.isEmpty {
                AppLog.shared.append(line)
            }
            statusMonitor?.refreshStatus(reason: "connect", force: true, reloadPreferences: false)
        } catch {
            statusMonitor?.endConnectAttempt()
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vpnState = .error(message: message)
            AppLog.shared.append("[vpn] connect failed: \(message)")
        }
    }

    func disconnect() async {
        guard !vpnState.isBusy else { return }

        if vpnState.isConnected {
            vpnState = .disconnecting
            resetThroughput()
        }
        AppLog.shared.append("[ui] disconnect")
        statusMonitor?.endConnectAttempt()

        do {
            try await vpn.disconnect()
            statusMonitor?.refreshStatus(reason: "disconnect", force: true)
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vpnState = .error(message: message)
            AppLog.shared.append("[vpn] disconnect failed: \(message)")
        }
    }

    func toggleVpn() async {
        if vpnState.isConnected {
            await disconnect()
        } else {
            await connect()
        }
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
        #if os(iOS) || os(macOS)
        throughputBaseline = nil
        #endif
        downloadBps = 0
        uploadBps = 0
    }

    #if os(iOS) || os(macOS)
    func runHomeThroughputSampling() async {
        throughputBaseline = nil
        while !Task.isCancelled {
            await sampleThroughputIfConnected()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func sampleThroughputIfConnected() async {
        guard vpnState.isConnected else {
            resetThroughput()
            return
        }
        guard !throughputSampling else { return }
        throughputSampling = true
        defer { throughputSampling = false }

        let tunnelOnly = true
        let totals = await Task.detached(priority: .utility) {
            DeviceTrafficTotals.cumulativeRXTXBytes(vpnTunnelOnly: tunnelOnly)
        }.value
        guard let totals else {
            resetThroughput()
            return
        }

        let now = Date()
        if let base = throughputBaseline {
            let dt = now.timeIntervalSince(base.at)
            if dt > 0 {
                let drx = Int64(totals.rx) - Int64(base.rx)
                let dtx = Int64(totals.tx) - Int64(base.tx)
                if drx >= 0, dtx >= 0 {
                    downloadBps = Double(drx) / dt
                    uploadBps = Double(dtx) / dt
                } else {
                    downloadBps = 0
                    uploadBps = 0
                }
            }
        }
        throughputBaseline = (totals.rx, totals.tx, now)
    }
    #endif
    #endif
}
