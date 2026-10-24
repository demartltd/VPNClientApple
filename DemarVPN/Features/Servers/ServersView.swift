import SwiftUI

struct ServersView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    var onNeedSignIn: (() -> Void)?
    @State private var detailsProfile: ServerProfile?
    @State private var showFilters = false

    private var filteredServers: [ServerProfile] {
        appState.servers.filterServers(
            tiers: appState.filterTiers,
            protocols: appState.filterProtocols,
            favoriteIds: appState.favoriteServerIds
        )
    }

    var body: some View {
        Group {
            if isActive { content } else { Color.clear }
        }
        .task(id: isActive) {
            guard isActive else { return }
            appState.setServersTabActive(true)
            guard appState.isSignedIn, appState.servers.isEmpty else { return }
            await appState.refreshSessionData()
        }
        .onChange(of: isActive) { _, active in
            if !active {
                appState.setServersTabActive(false)
                detailsProfile = nil
            }
        }
        .onChange(of: appState.servers.map(\.id)) { _, ids in
            if let id = detailsProfile?.id, !ids.contains(id) {
                detailsProfile = nil
            }
        }
        .demarBottomSheet(isPresented: Binding(
            get: { detailsProfile != nil },
            set: { if !$0 { detailsProfile = nil } }
        )) {
            if let profile = detailsProfile {
                ServerDetailsSheet(
                    profile: profile,
                    reachState: appState.serverReachability[profile.id] ?? .checking,
                    trafficBytes: appState.traffic?.bytesForServer(profile.displayName),
                    favorite: appState.favoriteServerIds.contains(profile.id),
                    onToggleFavorite: { appState.toggleFavoriteServer(profile.id) }
                )
            }
        }
        .demarBottomSheet(isPresented: $showFilters) {
            ServerFiltersSheet(appState: appState)
        }
    }

    private var content: some View {
        Group {
            if !appState.isSignedIn {
                guestState
            } else {
                signedInContent
            }
        }
        .background(Color.demarSurface)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .tint(.white)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await pullRefresh() }
                } label: {
                    if appState.isRefreshingServers || (appState.serversLoading && appState.servers.isEmpty) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white)
                    }
                }
                .help(String(localized: "Refresh servers"))
                .disabled(!appState.isSignedIn || appState.isRefreshingServers || appState.serversLoading)

                Button {
                    showFilters = true
                } label: {
                    Image(systemName: appState.filtersActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.white)
                }
                .help(String(localized: "Server filters"))
            }
        }
    }

    private var serversHeroTitle: some View {
        Text(String(localized: "Servers"))
            .font(.largeTitle.bold())
            .foregroundStyle(Color.demarOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }

    private var guestState: some View {
        VStack(spacing: 0) {
            serversHeroTitle
                .padding(.horizontal, 16)
            Spacer()
            Text(String(localized: "Sign in to see available servers"))
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(String(localized: "Sign in")) { onNeedSignIn?() }
                .buttonStyle(.borderedProminent)
                .tint(Color.demarPrimary)
                .padding(.top, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedInContent: some View {
        // List (UITableView) — ScrollView + refresh inset breaks SwiftUI hit-testing mid-animation.
        List {
            Section {
                serversHeroTitle
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if appState.serversLoading, appState.servers.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if let err = appState.serversError, appState.servers.isEmpty {
                    VStack(spacing: 12) {
                        Text(err.isEmpty ? String(localized: "Couldn’t load servers") : err)
                            .font(.demarBodyMedium)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                        Button(String(localized: "Retry")) {
                            Task { await appState.refreshSessionData(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.demarPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .padding(.horizontal, 8)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if filteredServers.isEmpty {
                    Text(String(localized: "No servers available for your subscription"))
                        .font(.demarBodyMedium)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredServers) { server in
                        ServerRow(
                            profile: server,
                            selected: appState.selectedServer?.id == server.id,
                            favorite: appState.favoriteServerIds.contains(server.id),
                            reachState: appState.serverReachability[server.id] ?? .checking,
                            onSelect: { selectServer(byId: server.id) },
                            onDetails: { detailsProfile = server },
                            onNeedUpgrade: { appState.openCheckout(.buy) }
                        )
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.always)
        .background(Color.demarSurface)
        #if os(iOS)
        .refreshable { await pullRefresh() }
        #endif
        .scrollIndicators(.hidden)
        .animation(.none, value: filteredServers.map(\.id))
    }

    private func selectServer(byId id: String) {
        guard let server = appState.servers.first(where: { $0.id == id })
            ?? filteredServers.first(where: { $0.id == id })
        else { return }
        Task {
            let wouldReconnect =
                appState.vpnState.isConnected
                || appState.vpnState.isBusy
                || appState.vpnState.hasError
            await appState.switchServer(to: server)
            if !server.canConnect, wouldReconnect {
                snackBar.showWarning(String(localized: "Connecting is unavailable for the Review account"))
            } else {
                snackBar.showSuccess(String(localized: "Server selected"))
            }
        }
    }

    private func pullRefresh() async {
        guard appState.isSignedIn else { return }
        AppLog.shared.append("[ui] servers refresh")
        let ok = await appState.pullRefreshServers()
        if ok {
            snackBar.showSuccess(String(localized: "Servers updated"))
        } else if appState.serversError != nil {
            snackBar.showInfo(appState.serversError ?? String(localized: "Couldn’t refresh"))
        }
    }
}

private struct ServerRow: View {
    let profile: ServerProfile
    let selected: Bool
    let favorite: Bool
    let reachState: ServerReachState
    let onSelect: () -> Void
    let onDetails: () -> Void
    let onNeedUpgrade: () -> Void

    private let rowMinHeight: CGFloat = 72
    private let trailingMinWidth: CGFloat = 72

    var body: some View {
        let locked = profile.isLocked
        let highlight = !locked && selected
        let muted = highlight ? Color.demarOnPrimaryContainer.opacity(0.75) : Color.demarOnSurfaceVariant
        let subtitle = profile.listSubtitle

        // No nested Buttons — List + Button hit-testing drifts during refresh animation.
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                CountryFlagView(code: profile.countryCode, emoji: profile.flagEmoji)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if favorite, !locked {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.demarError)
                        }
                        Text(profile.titleName)
                            .font(.demarTitleMediumBold)
                            .foregroundStyle(highlight ? Color.demarOnPrimaryContainer : Color.demarOnSurface)
                            .lineLimit(1)
                        ServerBadge(label: profile.tier.label, tier: profile.tier)
                        ProtocolServerBadges(profile: profile)
                    }
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .font(.demarBodySmall)
                        .foregroundStyle(muted)
                        .opacity(subtitle.isEmpty ? 0 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(perform: locked ? onNeedUpgrade : onSelect)

            if locked {
                Text("Premium")
                    .font(.demarLabelLarge)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.demarOnPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.demarPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(minWidth: trailingMinWidth, minHeight: rowMinHeight, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNeedUpgrade)
            } else {
                HStack(spacing: 4) {
                    let ping = ServerReachState.formatListLabel(reachState, protocol: profile.serverProtocol)
                    if !ping.isEmpty {
                        Text(ping)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(muted)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(muted)
                }
                .frame(minWidth: trailingMinWidth, minHeight: rowMinHeight, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDetails)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: rowMinHeight)
        .background {
            ZStack {
                (highlight ? Color.demarPrimaryContainer : Color.demarSurfaceContainerHighest)
                if locked {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.28),
                            Color.black.opacity(0.14),
                            Color.black.opacity(0.04),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    highlight ? Color.demarPrimary.opacity(0.35) : Color.demarOutline.opacity(0.2),
                    lineWidth: 1
                )
        )
        .transaction { $0.disablesAnimations = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.displayName)
    }
}
