import Foundation
import Observation
#if os(iOS) || os(macOS)
import NetworkExtension
#endif
#if os(iOS)
import WidgetKit
#endif

enum PayFeedback: Equatable {
    case success, failure
}

@MainActor
@Observable
final class AppState {
    enum StorageKey {
        static let selectedServerId = "selected_server_id"
    }

    var servers: [ServerProfile] = []
    var selectedServer: ServerProfile?
    var isRefreshingServers = false
    var serversLoading = false
    var serversError: String?
    var serverReachability: [String: ServerReachState] = [:]
    var favoriteServerIds: Set<String> = []
    var filterTiers: Set<ServerTier> = Set(ServerTier.allCases)
    var filterProtocols: Set<ServerProtocol> = Set(ServerProtocol.allCases)
    var reachabilityTask: Task<Void, Never>?
    var serversTabActive = false
    var initialReachabilityDone = false
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
    /// Deeplink / in-app account sheet when guest must sign in first.
    var pendingAccountSheet: DemarDeepLink.AccountSheet?
    var lastPayReturnRefreshAt: Date?
    var accountRouteRequestTick: Int = 0
    /// Active account/pay bottom sheet (`nil` = none).
    var accountSheet: AccountFlowSheet?
    var latestAppVersion: AppVersionInfo?
    var shouldShowUpdateAlert = false
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

    let vpn: VpnControlling
    var vpnOperationGeneration: UInt64 = 0
    var shownUpdateTokenInSession: String?
    var backgroundRefreshTask: Task<Void, Never>?
    var lastSessionDataRefreshAt: Date?
    /// Last `refreshSessionData` start (success or fail) — used for API failure cooldown.
    var lastSessionRefreshAttemptAt: Date?
    static let sessionDataTTL: TimeInterval = SessionRefreshPolicy.ttl
    static let backgroundRefreshInterval: Duration = .seconds(sessionDataTTL)

    #if os(iOS) || os(macOS)
    var statusMonitor: VpnStatusMonitor?
    #endif

    init(vpn: VpnControlling? = nil) {
        let session = AuthSessionStore.session
        authSession = session
        favoriteServerIds = ServersPreferencesStore.favorites
        filterTiers = ServersPreferencesStore.tiers
        filterProtocols = ServersPreferencesStore.protocols
        if let session, let cached = SessionCacheStore.load(userId: session.userId) {
            servers = cached.servers
            selectedServer = Self.restoreSelectedServer(from: cached.servers)
            serverReachability = cached.reachability
            account = cached.account
            traffic = cached.traffic
            TunSettingsStore.hydrateFromCache(cached.tunRaw)
            AppLog.shared.append("[session] restored cache (servers=\(cached.servers.count), tun=\(cached.tunRaw != nil))")
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
        applyTunDefaultsIfFree()
        sanitizeFiltersAgainstServers()
    }

    static func restoreSelectedServer(from servers: [ServerProfile]) -> ServerProfile? {
        let lastId = UserDefaults.standard.string(forKey: StorageKey.selectedServerId)
        return servers.pickSelected(currentId: lastId, lastId: lastId)
    }

    static func persistSelectedServerId(_ id: String) {
        UserDefaults.standard.set(id, forKey: StorageKey.selectedServerId)
    }

    /// Active when any visible badge chip is off (not when unused DEV/TESTER differ).
    var filtersActive: Bool {
        let tiers = Set(servers.visibleTiers())
        let protocols = Set(servers.visibleProtocols())
        return !tiers.isSubset(of: filterTiers) || !protocols.isSubset(of: filterProtocols)
    }

    func toggleFavoriteServer(_ id: String) {
        favoriteServerIds = ServersPreferencesStore.toggleFavorite(id)
    }

    func setFilterTiers(_ next: Set<ServerTier>) {
        guard servers.matchesFilters(tiers: next, protocols: filterProtocols) else { return }
        filterTiers = next.isEmpty ? Set(ServerTier.allCases) : next
        ServersPreferencesStore.tiers = filterTiers
    }

    func setFilterProtocols(_ next: Set<ServerProtocol>) {
        guard servers.matchesFilters(tiers: filterTiers, protocols: next) else { return }
        filterProtocols = next.isEmpty ? Set(ServerProtocol.allCases) : next
        ServersPreferencesStore.protocols = filterProtocols
    }

    /// Spec §3: stale filters that match nobody after a refresh → full reset.
    func sanitizeFiltersAgainstServers() {
        guard !servers.isEmpty,
              !servers.matchesFilters(tiers: filterTiers, protocols: filterProtocols)
        else { return }
        filterTiers = Set(ServerTier.allCases)
        filterProtocols = Set(ServerProtocol.allCases)
        ServersPreferencesStore.tiers = filterTiers
        ServersPreferencesStore.protocols = filterProtocols
    }
}
