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

    var servers: [ServerProfile] = []
    var selectedServer: ServerProfile?
    var isRefreshingServers = false
    var serversLoading = false
    var serversError: String?
    var account: VpnAccount?
    var traffic: VpnTraffic?
    var trafficExceeded = false
    var accountLoading = false
    var vpnState: VpnConnectionState = .disconnected
    var downloadBps: Double = 0
    var uploadBps: Double = 0
    var authSession: AuthSession?
    /// Bumped after OAuth deep-link handoff so UI can navigate to return tab.
    var authCallbackTick: Int = 0
    /// Pending settings route requested by incoming URL / public link.
    var pendingSettingsRoute: SettingsRoute?
    var settingsRouteRequestTick: Int = 0
    /// Open Account tab + traffic bottom sheet (`demarvpn://settings/traffic`).
    var pendingOpenTrafficSheet = false
    var accountRouteRequestTick: Int = 0
    var latestAppVersion: AppVersionInfo?
    var shouldShowUpdateAlert = false
    var versionCheckInFlight = false
    var versionCheckError: String?

    var appVersionLabel: String = "1.0.6"
    var appVersionDetailLabel: String {
        "\(appVersionLabel) (\(installedBuildNumber))"
    }
    var installedBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    var actualVersionLabel: String { latestAppVersion?.version ?? "…" }
    var isUpdateAvailable: Bool {
        latestAppVersion?.isNewer(thanInstalledBuild: installedBuildNumber) == true
    }
    var coreVersionToken: String = BundledCoreVersion.label
    var isSignedIn: Bool { authSession != nil }

    private let vpn: VpnControlling
    private var vpnOperationGeneration: UInt64 = 0
    private var versionCheckTask: Task<Void, Never>?
    private var shownUpdateTokenInSession: String?
    #if os(macOS)
    private var macVersionPollingTask: Task<Void, Never>?
    #endif

    #if os(iOS) || os(macOS)
    private var statusMonitor: VpnStatusMonitor?
    #endif

    init(vpn: VpnControlling? = nil) {
        let session = AuthSessionStore.session
        authSession = session
        if let session, let cached = SessionCacheStore.load(userId: session.userId) {
            servers = cached.servers
            selectedServer = Self.restoreSelectedServer(from: cached.servers)
            account = cached.account
            traffic = cached.traffic
            AppLog.shared.append("[session] restored cache (servers=\(cached.servers.count))")
        } else {
            selectedServer = nil
        }
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
            AppLog.shared.append("[app] packet-tunnel: disabled — enable Demar Proxy in System Settings → Login Items & Extensions → Network Extensions")
        }
        #endif
        #else
        self.vpn = vpn ?? NativeVpnService()
        #endif
    }

    var canToggleVpn: Bool {
        if case .disconnecting = vpnState { return false }
        return vpnState.isConnected || vpnState == .connecting || selectedServer != nil
    }

    func bootstrapAuth() async {
        refreshVersionIfNeeded(force: true)
        authSession = AuthSessionStore.session
        _ = await AuthSessionStore.refreshSession()
        authSession = AuthSessionStore.session
        if isSignedIn {
            await refreshSessionData()
        } else {
            await applyLocalSignOut()
        }
    }

    func onAuthSuccess() async {
        authSession = AuthSessionStore.session
        refreshVersionIfNeeded(force: true)
        await refreshSessionData()
    }

    func consumeIncomingURL(_ url: URL) async {
        if await consumeAuthCallback(url) { return }
        if DemarURLScheme.isAccountTrafficURL(url) {
            openAccountTrafficSheet()
            return
        }
        guard let route = SettingsRoute(url: url) else { return }
        pendingSettingsRoute = route
        settingsRouteRequestTick &+= 1
    }

    @discardableResult
    func consumePendingSettingsRoute() -> SettingsRoute? {
        defer { pendingSettingsRoute = nil }
        return pendingSettingsRoute
    }

    func openAccountTrafficSheet() {
        pendingOpenTrafficSheet = true
        accountRouteRequestTick &+= 1
    }

    @discardableResult
    func consumeOpenTrafficSheetRequest() -> Bool {
        defer { pendingOpenTrafficSheet = false }
        return pendingOpenTrafficSheet
    }

    private func consumeAuthCallback(_ url: URL) async -> Bool {
        guard url.scheme == DemarURLScheme.name, url.host == "auth" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        do {
            if let token = items.first(where: { $0.name == "token" })?.value?.nilIfBlank {
                try await AuthSessionStore.completeClientToken(token)
            } else if let code = items.first(where: { $0.name == "code" })?.value?.nilIfBlank {
                try await AuthSessionStore.completeExchange(code)
            } else {
                return false
            }
            await onAuthSuccess()
            authCallbackTick &+= 1
        } catch {
            AppLog.shared.append("[auth] callback failed — \(error.localizedDescription)")
        }
        return true
    }

    /// Stops VPN and clears local state only after server logout succeeds (or session already gone).
    func signOut() async throws {
        try await AuthSessionStore.signOut()
        await applyLocalSignOut()
    }

    /// Clears local auth + servers and disconnects VPN (no server logout call).
    func forceLocalSignOut() async {
        AuthSessionStore.clearLocal()
        await applyLocalSignOut()
        AppLog.shared.append("[auth] forced local sign-out")
    }

    private func applyLocalSignOut() async {
        authSession = nil
        SessionCacheStore.clear()
        SupportStore.clearOnSignOut()
        clearServers()
        clearAccount()
        await revokeVpnAccess()
    }

    /// Stops tunnel, clears reconnect payload/config, removes NE profile (CC/Settings cannot reconnect).
    private func revokeVpnAccess() async {
        #if os(iOS) || os(macOS)
        beginVpnOperation()
        statusMonitor?.endConnectAttempt()
        if vpnState.isConnected || vpnState == .connecting {
            vpnState = .disconnecting
            resetThroughput()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            VpnTunnelController.shared.revokeAccess { continuation.resume() }
        }
        vpnState = .disconnected
        resetThroughput()
        statusMonitor?.refreshStatus(reason: "signOut", force: true)
        #if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
        #endif
        AppLog.shared.append("[auth] vpn access revoked")
        #endif
    }

    /// Session data — app start, sign-in, pull-to-refresh, promo activation.
    func refreshSessionData() async {
        async let servers: Void = refreshServers()
        async let account: Void = refreshAccount()
        async let unread: Void = refreshSupportUnread()
        _ = await (servers, account, unread)
    }

    private func refreshSupportUnread() async {
        guard let session = AuthSessionStore.session else {
            SupportUnreadStore.shared.clear()
            return
        }
        await SupportUnreadStore.shared.refresh(session: session)
    }

    private func refreshAccount() async {
        guard let session = AuthSessionStore.session else {
            clearAccount()
            return
        }
        guard !accountLoading else { return }
        accountLoading = true
        defer { accountLoading = false }

        if session.isLocalDemo {
            let local = LocalDemoAccount.vpnAccount()
            account = local
            traffic = LocalDemoAccount.vpnTraffic()
            AuthSessionStore.updateVpnProfile(local.vpnSubscription, local.vpnExpiresAt)
            authSession = AuthSessionStore.session
            SessionCacheStore.saveAccount(local, userId: session.userId)
            SessionCacheStore.saveTraffic(LocalDemoAccount.vpnTraffic(), userId: session.userId)
            AppLog.shared.append("[account] loaded (local demo)")
            return
        }

        async let aRes: Result<VpnAccount, Error> = {
            do { return .success(try await VpnAccountApi.fetchAccount(userId: session.userId, loginAt: session.loginAt)) }
            catch { return .failure(error) }
        }()
        async let tRes: Result<VpnTraffic, Error> = {
            do { return .success(try await VpnAccountApi.fetchTraffic(userId: session.userId, loginAt: session.loginAt)) }
            catch { return .failure(error) }
        }()
        let (accountResult, trafficResult) = await (aRes, tRes)

        if case .success(let a) = accountResult {
            account = a
            AuthSessionStore.updateVpnProfile(a.vpnSubscription, a.vpnExpiresAt)
            authSession = AuthSessionStore.session
            SessionCacheStore.saveAccount(a, userId: session.userId)
        }
        if case .success(let t) = trafficResult {
            traffic = t
            SessionCacheStore.saveTraffic(t, userId: session.userId)
        }

        let err: Error? = switch accountResult {
        case .failure(let e): e
        case .success: switch trafficResult {
            case .failure(let e): e
            case .success: nil
            }
        }
        if err is CancellationError { return }
        if let e = err as? DemarAPIError, e.isSessionInvalid {
            await forceLocalSignOut()
            return
        }
        if let err {
            AppLog.shared.append("[account] load failed — \(err.localizedDescription)")
        } else {
            AppLog.shared.append("[account] refreshed")
        }
    }

    private func refreshServers() async {
        guard let session = AuthSessionStore.session else {
            clearServers()
            return
        }
        guard !serversLoading else { return }
        serversLoading = true
        serversError = nil
        defer { serversLoading = false }
        do {
            let result = try await ServersApi.fetchServers(userId: session.userId, loginAt: session.loginAt)
            applyServerList(result.servers)
            trafficExceeded = result.trafficExceeded
            SessionCacheStore.saveServers(result.rawJson, userId: session.userId)
            AppLog.shared.append("[servers] loaded \(result.servers.count) (sub=\(result.vpnSubscription ?? "—"))")
        } catch is CancellationError {
            return
        } catch let e as DemarAPIError where e.isSessionInvalid {
            if session.isLocalDemo {
                serversError = e.message.nilIfBlank ?? String(localized: "Couldn’t load servers")
                AppLog.shared.append("[servers] demo fetch unauthorized — keeping session")
            } else {
                await forceLocalSignOut()
                AppLog.shared.append("[servers] session revoked")
            }
        } catch {
            serversError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.shared.append("[servers] fetch failed — \(serversError ?? "")")
        }
    }

    /// Pull-to-refresh: banner + network fetch (min visible duration).
    func pullRefreshServers(minimumVisibleDuration: Duration = .seconds(1.5)) async -> Bool {
        guard beginServersRefresh() else { return false }
        defer { isRefreshingServers = false }
        async let sleep: Void = { try? await Task.sleep(for: minimumVisibleDuration) }()
        await refreshSessionData()
        await sleep
        return !Task.isCancelled && serversError == nil
    }

    private func clearAccount() {
        account = nil
        traffic = nil
        trafficExceeded = false
        accountLoading = false
    }

    func isTrafficConnectBlocked() -> Bool {
        trafficExceeded
    }

    private func applyServerList(_ list: [ServerProfile]) {
        servers = list
        selectedServer = Self.restoreSelectedServer(from: list)
    }

    private func clearServers() {
        servers = []
        selectedServer = nil
        serversError = nil
        serversLoading = false
        trafficExceeded = false
        UserDefaults.standard.removeObject(forKey: StorageKey.selectedServerId)
    }

    func refreshVersionIfNeeded(force: Bool = false) {
        guard !versionCheckInFlight else { return }
        if force {
            versionCheckTask?.cancel()
            versionCheckTask = nil
        } else if versionCheckTask != nil {
            return
        }
        versionCheckTask = Task { [weak self] in
            await self?.performVersionCheck()
        }
    }

    func dismissUpdateAlert() {
        shouldShowUpdateAlert = false
    }

    func presentCachedUpdateAlertIfNeeded() {
        guard let latestAppVersion else { return }
        presentUpdateAlertIfNeeded(for: latestAppVersion)
    }

    func rearmUpdateAlertForNextActive() {
        shouldShowUpdateAlert = false
        shownUpdateTokenInSession = nil
    }

    #if os(macOS)
    func setAppActive(_ active: Bool) {
        if active {
            startMacVersionPollingIfNeeded()
        } else {
            stopMacVersionPolling()
        }
    }
    #endif

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
        guard shouldReconnect, server.canConnect else { return }

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

    func connect() async {
        let generation = beginVpnOperation()
        let force: Bool
        if case .error = vpnState { force = true }
        else { force = false }
        await connect(force: force, operationGeneration: generation)
    }

    private func connect(force: Bool, operationGeneration: UInt64) async {
        if isTrafficConnectBlocked() {
            AppLog.shared.append("[vpn] connect blocked: traffic limit")
            openAccountTrafficSheet()
            return
        }
        guard let server = selectedServer, server.canConnect else { return }
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

    func beginServersRefresh() -> Bool {
        guard !isRefreshingServers else { return false }
        isRefreshingServers = true
        return true
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
        guard !servers.isEmpty else { return nil }
        guard let savedId = UserDefaults.standard.string(forKey: StorageKey.selectedServerId) else {
            return servers.first
        }
        return servers.first(where: { $0.id == savedId }) ?? servers.first
    }

    private static func persistSelectedServerId(_ id: String) {
        UserDefaults.standard.set(id, forKey: StorageKey.selectedServerId)
    }

    private func performVersionCheck() async {
        versionCheckInFlight = true
        versionCheckError = nil
        defer {
            versionCheckInFlight = false
            versionCheckTask = nil
        }
        do {
            applyLatestVersion(try await AppVersionApi.fetchLatest())
        } catch is CancellationError {
            return
        } catch {
            versionCheckError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.shared.append("[version] check failed — \(versionCheckError ?? "")")
        }
    }

    private func applyLatestVersion(_ latest: AppVersionInfo) {
        latestAppVersion = latest
        guard latest.isNewer(thanInstalledBuild: installedBuildNumber) else {
            rearmUpdateAlertForNextActive()
            return
        }
        presentUpdateAlertIfNeeded(for: latest)
        AppLog.shared.append("[version] update available \(latest.version)")
    }

    private func presentUpdateAlertIfNeeded(for latest: AppVersionInfo) {
        guard latest.isNewer(thanInstalledBuild: installedBuildNumber) else { return }
        guard shownUpdateTokenInSession != latest.token else { return }
        shownUpdateTokenInSession = latest.token
        shouldShowUpdateAlert = true
    }

    #if os(macOS)
    private func startMacVersionPollingIfNeeded() {
        guard macVersionPollingTask == nil else { return }
        macVersionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { break }
                await self?.refreshVersionIfNeeded()
            }
        }
    }

    private func stopMacVersionPolling() {
        macVersionPollingTask?.cancel()
        macVersionPollingTask = nil
    }
    #endif

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
}
