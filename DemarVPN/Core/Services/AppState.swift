import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let servers: [ServerProfile]
    var selectedServer: ServerProfile?
    var vpnState: VpnConnectionState = .disconnected
    var downloadBps: Double = 0
    var uploadBps: Double = 0

    var appVersionLabel: String = "1.0.0"
    var xrayVersionToken: String = BundledXrayVersion.label

    private let vpn: VpnControlling
    private var throughputTask: Task<Void, Never>?

    #if os(iOS)
    private var statusMonitor: VpnStatusMonitor?
    #endif

    init(vpn: VpnControlling? = nil) {
        servers = TestServers.profiles
        selectedServer = servers.first
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            appVersionLabel = bundleVersion
        }

        #if os(iOS)
        self.vpn = vpn ?? IosVpnService()
        xrayVersionToken = BundledXrayVersion.label
        let monitor = VpnStatusMonitor()
        monitor.onStatusChange = { [weak self] state in
            self?.applyRemoteVpnState(state)
        }
        statusMonitor = monitor
        monitor.start()
        #else
        self.vpn = vpn ?? MockVpnControlling()
        #endif
    }

    var canToggleVpn: Bool {
        !vpnState.isBusy && (vpnState.isConnected || selectedServer != nil)
    }

    func selectServer(_ server: ServerProfile) {
        selectedServer = server
        AppLog.shared.append("[ui] server selected: \(server.displayName)")
    }

    func connect() async {
        guard let server = selectedServer else { return }
        guard !vpnState.isBusy else { return }

        vpnState = .connecting
        downloadBps = 0
        uploadBps = 0
        stopThroughputMock()
        AppLog.shared.append("[ui] connect → \(server.displayName)")

        do {
            try await vpn.connect(server: server)
            #if os(iOS)
            statusMonitor?.refreshStatus(reason: "connect", force: true)
            #elseif os(macOS)
            if !Task.isCancelled {
                vpnState = .connected
                AppLog.shared.append("[mock] VPN connected")
                startThroughputMock()
            }
            #endif
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vpnState = .error(message: message)
            AppLog.shared.append("[vpn] connect failed: \(message)")
        }
    }

    func disconnect() async {
        guard !vpnState.isBusy else { return }

        vpnState = .disconnecting
        stopThroughputMock()
        AppLog.shared.append("[ui] disconnect")

        do {
            try await vpn.disconnect()
            #if os(iOS)
            statusMonitor?.refreshStatus(reason: "disconnect", force: true)
            #elseif os(macOS)
            if !Task.isCancelled {
                vpnState = .disconnected
                downloadBps = 0
                uploadBps = 0
                AppLog.shared.append("[mock] VPN disconnected")
            }
            #endif
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

    #if os(iOS)
    func syncVpnStatusFromSystem() {
        statusMonitor?.refreshStatus(reason: "sync", force: true)
    }

    private func applyRemoteVpnState(_ state: VpnConnectionState) {
        vpnState = state
        switch state {
        case .connected:
            startThroughputMock()
        case .disconnected, .error:
            stopThroughputMock()
            downloadBps = 0
            uploadBps = 0
        case .connecting, .disconnecting:
            stopThroughputMock()
            downloadBps = 0
            uploadBps = 0
        }
    }
    #endif

    private func startThroughputMock() {
        #if os(macOS)
        stopThroughputMock()
        throughputTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.vpnState.isConnected else { continue }
                self.downloadBps = MockVpnService.mockDownloadBps
                self.uploadBps = MockVpnService.mockUploadBps
            }
        }
        #endif
    }

    private func stopThroughputMock() {
        throughputTask?.cancel()
        throughputTask = nil
    }
}
