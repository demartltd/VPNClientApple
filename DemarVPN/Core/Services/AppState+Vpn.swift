import Foundation
import Observation
#if os(iOS) || os(macOS)
import NetworkExtension
#endif
#if os(iOS)
import WidgetKit
#endif

@MainActor
extension AppState {
    func beginVpnOperation() -> UInt64 {
        vpnOperationGeneration &+= 1
        #if os(iOS) || os(macOS)
        VpnTunnelController.shared.cancelConnectOperation()
        #endif
        return vpnOperationGeneration
    }

    func isCurrentVpnOperation(_ generation: UInt64) -> Bool {
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
        guard shouldReconnect, server.canConnect else { return }

        let generation = beginVpnOperation()
        statusMonitor?.endConnectAttempt()
        vpnState = .disconnecting
        resetThroughput()
        do {
            #if os(iOS) || os(macOS)
            // Resolve new uplink while network is still stable (before TUN tear-down).
            // connect(force) must not clear this cache.
            let uplink = server.connectPlan.uplinkHost
            _ = try? await Task.detached(priority: .userInitiated) {
                try UplinkIPv4Resolver.resolve(uplink)
            }.value
            #endif
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

    func connect() async {
        let generation = beginVpnOperation()
        let force: Bool
        if case .error = vpnState { force = true }
        else { force = false }
        await connect(force: force, operationGeneration: generation)
    }

    func connect(force: Bool, operationGeneration: UInt64) async {
        if isTrafficConnectBlocked() {
            AppLog.shared.append("[vpn] connect blocked: traffic limit")
            openTrafficOrFreeAlert()
            return
        }
        // Connect from cache — never gate VPN start on API (avoids spam when API is down / rate-limited).
        guard let server = selectedServer, server.canConnect else { return }
        var shouldForce = force
        #if os(iOS) || os(macOS)
        let systemStatus = await withCheckedContinuation { (continuation: CheckedContinuation<NEVPNStatus, Never>) in
            VpnTunnelController.shared.currentStatus { status in
                continuation.resume(returning: status)
            }
        }
        guard isCurrentVpnOperation(operationGeneration) else { return }
        let neActive = systemStatus == .connected || systemStatus == .connecting || systemStatus == .reasserting
        if !shouldForce, neActive {
            let hasPayload = (try? VpnSharedStore.loadConnectPayload()) != nil
            if hasPayload {
                AppLog.shared.append("[ui] connect ignored: system tunnel already active (\(systemStatus.rawValue))")
                statusMonitor?.refreshStatus(reason: "connect-noop", force: true, reloadPreferences: false)
                return
            }
            AppLog.shared.append("[ui] connect force: NE active without payload")
            shouldForce = true
        }
        if shouldForce, neActive {
            AppLog.shared.append("[ui] connect force: stopping leftover NE status=\(systemStatus.rawValue)")
            try? await vpn.disconnect()
            _ = await waitUntilSystemDisconnected(timeoutSeconds: 8)
            guard isCurrentVpnOperation(operationGeneration) else { return }
        }
        #endif
        if !shouldForce, vpnState.isConnected {
            AppLog.shared.append("[ui] connect ignored: already connected")
            statusMonitor?.refreshStatus(reason: "connect-noop-ui", force: true, reloadPreferences: false)
            return
        }
        if case .connecting = vpnState, !shouldForce { return }
        guard shouldForce || !vpnState.isBusy else { return }

        if case .disconnected = vpnState {
            vpnState = .connecting
            resetThroughput()
        } else if shouldForce {
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
            await removeAllDemarVPNProfiles()
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
    func waitUntilSystemDisconnected(timeoutSeconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            VpnTunnelController.shared.waitUntilDisconnected(timeout: timeoutSeconds) { idle in
                continuation.resume(returning: idle)
            }
        }
    }

    func removeAllDemarVPNProfiles() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            VpnTunnelController.shared.removeAllDemarVPNProfiles {
                continuation.resume()
            }
        }
    }
    #endif

    func beginServersRefresh() -> Bool {
        guard !isRefreshingServers else { return false }
        isRefreshingServers = true
        return true
    }

    #if os(iOS) || os(macOS)
    func syncVpnStatusFromSystem() {
        ensureOpenFluxHostIfNeeded()
        statusMonitor?.importForegroundDiagnostics()
        statusMonitor?.refreshStatus(reason: "sync", force: true, reloadPreferences: false)
        #if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
        #endif
    }

    /// OpenFlux SOCKS lives in the host process; after suspend/crash NE can stay
    /// "connected" with a dead :11080 — restore before traffic is expected again.
    func ensureOpenFluxHostIfNeeded() {
        guard VpnSharedStore.loadOpenFluxSidecar() != nil else { return }
        do {
            try OpenFluxHostProcess.ensureSidecarRunning()
        } catch {
            AppLog.shared.append("[vpn] openflux ensure failed: \(error.localizedDescription)")
        }
    }

    func applyRemoteVpnState(_ state: VpnConnectionState) {
        let wasConnected = vpnState.isConnected
        vpnState = state
        if !state.isConnected { resetThroughput() }
        if wasConnected != state.isConnected {
            Task { await DemarHttp.resetTransport() }
        }
    }
    #endif

    func resetThroughput() {
        downloadBps = 0
        uploadBps = 0
    }

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
}
