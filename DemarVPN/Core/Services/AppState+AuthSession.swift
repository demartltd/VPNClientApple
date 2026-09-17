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
    func bootstrapAuth() async {
        let upgraded = AppRuntimeUpgrade.consumeIfUpgraded()
        if upgraded {
            AppLog.shared.append("[vpn] runtime upgrade — cleared connect artifacts + NE profile")
            #if os(iOS) || os(macOS)
            try? await vpn.disconnect()
            _ = await waitUntilSystemDisconnected(timeoutSeconds: 8)
            await removeAllDemarVPNProfiles()
            vpnState = .disconnected
            resetThroughput()
            #endif
        }
        refreshVersion()
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
        refreshVersion()
        await refreshSessionData()
        presentPendingAccountSheetIfNeeded()
    }

    func consumeIncomingURL(_ url: URL) async {
        if await consumeAuthCallback(url) { return }
        guard let link = DemarDeepLink(url: url) else { return }
        switch link {
        case .account(let sheet):
            openAccountSheet(sheet)
        case .payReturn(let success):
            handlePayReturn(success: success)
        case .settings(let route):
            pendingSettingsRoute = route
            settingsRouteRequestTick &+= 1
        }
    }
    func consumeAuthCallback(_ url: URL) async -> Bool {
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

    func applyLocalSignOut() async {
        authSession = nil
        pendingAccountSheet = nil
        dismissCheckout()
        showPlanCompare = false
        SessionCacheStore.clear()
        TunSettingsStore.clearCatalog()
        SupportStore.clearOnSignOut()
        clearServers()
        clearAccount()
        lastSessionDataRefreshAt = nil
        await revokeVpnAccess()
    }

    /// Stops tunnel, clears reconnect payload/config, removes NE profile (CC/Settings cannot reconnect).
    func revokeVpnAccess() async {
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
        await Flight.run("session.refresh") {
            async let servers: Bool = self.refreshServers()
            async let account: Bool = self.refreshAccount()
            async let unread: Void = self.refreshSupportUnread()
            async let tun: Void = self.refreshTunGroups()
            async let plans: Void = PayApi.warmPlans()
            let (serversOk, accountOk) = await (servers, account)
            _ = await (unread, tun, plans)
            if serversOk || accountOk {
                self.lastSessionDataRefreshAt = Date()
            }
        }
    }

    func refreshSessionDataIfStale() async {
        guard isSignedIn else { return }
        guard SessionRefreshPolicy.isStale(since: lastSessionDataRefreshAt) else { return }
        _ = await AuthSessionStore.refreshSession()
        authSession = AuthSessionStore.session
        guard isSignedIn else { return }
        await refreshSessionData()
    }

    func refreshSupportUnread() async {
        guard let session = AuthSessionStore.session else {
            SupportUnreadStore.shared.clear()
            return
        }
        await SupportUnreadStore.shared.refresh(session: session)
    }

    @discardableResult
    func refreshAccount() async -> Bool {
        guard let session = AuthSessionStore.session else {
            clearAccount()
            return false
        }
        guard !accountLoading else { return false }
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
            applyTunDefaultsIfFree()
            AppLog.shared.append("[account] loaded (local demo)")
            return true
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
            applyTunDefaultsIfFree()
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
        if err is CancellationError { return false }
        if let e = err as? DemarAPIError, e.isSessionInvalid {
            await forceLocalSignOut()
            return false
        }
        if let err {
            AppLog.shared.append("[account] load failed — \(err.localizedDescription)")
            return false
        }
        AppLog.shared.append("[account] refreshed")
        return true
    }

    @discardableResult
    func refreshServers() async -> Bool {
        guard let session = AuthSessionStore.session else {
            clearServers()
            return false
        }
        guard !serversLoading else { return false }
        serversLoading = true
        serversError = nil
        defer { serversLoading = false }
        do {
            let result = try await ServersApi.fetchServers(userId: session.userId, loginAt: session.loginAt)
            applyServerList(result.servers)
            trafficExceeded = result.trafficExceeded
            SessionCacheStore.saveServers(result.rawJson, userId: session.userId)
            AppLog.shared.append("[servers] loaded \(result.servers.count) (sub=\(result.vpnSubscription ?? "—"))")
            return true
        } catch is CancellationError {
            return false
        } catch let e as DemarAPIError where e.isSessionInvalid {
            if session.isLocalDemo {
                serversError = e.message.nilIfBlank ?? String(localized: "Couldn’t load servers")
                AppLog.shared.append("[servers] demo fetch unauthorized — keeping session")
            } else {
                await forceLocalSignOut()
                AppLog.shared.append("[servers] session revoked")
            }
            return false
        } catch {
            serversError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.shared.append("[servers] fetch failed — \(serversError ?? "")")
            return false
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

    func clearAccount() {
        account = nil
        traffic = nil
        trafficExceeded = false
        accountLoading = false
    }

    func isTrafficConnectBlocked() -> Bool {
        trafficExceeded
    }

    func applyServerList(_ list: [ServerProfile]) {
        servers = list
        selectedServer = Self.restoreSelectedServer(from: list)
    }

    func clearServers() {
        servers = []
        selectedServer = nil
        serversError = nil
        serversLoading = false
        trafficExceeded = false
        UserDefaults.standard.removeObject(forKey: StorageKey.selectedServerId)
    }

    var isFreeSubscription: Bool {
        let raw = (account?.vpnSubscription ?? authSession?.vpnSubscription ?? "free")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw.caseInsensitiveCompare("free") == .orderedSame
    }

    func applyTunDefaultsIfFree() {
        guard isFreeSubscription else { return }
        TunSettingsStore.resetToDefaults()
    }

    func refreshTunGroups() async {
        guard let session = AuthSessionStore.session else { return }
        guard let payload = await TunGroupsApi.fetch() else { return }
        TunSettingsStore.cacheGroups(payload.catalog, raw: payload.raw, userId: session.userId)
        AppLog.shared.append("[tun] groups cached sites=\(payload.catalog.siteGroups.count)")
    }

    func refreshVersion() {
        Task { await Flight.run("version") { await self.performVersionCheck() } }
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

    func setAppActive(_ active: Bool) {
        if active {
            Task {
                await DemarHttp.resetTransport()
                startBackgroundRefreshIfNeeded()
            }
        } else {
            stopBackgroundRefresh()
        }
    }

    func performVersionCheck() async {
        versionCheckError = nil
        do {
            applyLatestVersion(try await AppVersionApi.fetchLatest())
        } catch is CancellationError {
            return
        } catch {
            versionCheckError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.shared.append("[version] check failed — \(versionCheckError ?? "")")
        }
    }

    func applyLatestVersion(_ latest: AppVersionInfo) {
        if latestAppVersion != latest {
            latestAppVersion = latest
        }
        guard latest.isNewer(thanInstalledBuild: installedBuildNumber) else {
            rearmUpdateAlertForNextActive()
            return
        }
        presentUpdateAlertIfNeeded(for: latest)
        AppLog.shared.append("[version] update available \(latest.version)")
    }

    func presentUpdateAlertIfNeeded(for latest: AppVersionInfo) {
        guard latest.isNewer(thanInstalledBuild: installedBuildNumber) else { return }
        guard shownUpdateTokenInSession != latest.token else { return }
        shownUpdateTokenInSession = latest.token
        shouldShowUpdateAlert = true
    }

    func startBackgroundRefreshIfNeeded() {
        guard backgroundRefreshTask == nil else { return }
        backgroundRefreshTask = Task { [weak self] in
            await self?.refreshSessionDataIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundRefreshInterval)
                guard !Task.isCancelled else { break }
                self?.refreshVersion()
                await self?.refreshSessionDataIfStale()
            }
        }
    }

    func stopBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
    }
}
