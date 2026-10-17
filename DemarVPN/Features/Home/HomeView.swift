import SwiftUI

struct HomeView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    var onNeedSignIn: (() -> Void)?
    @State private var showDetails = false

    var body: some View {
        Group {
            if isActive {
                activeContent
            } else {
                Color.clear
            }
        }
        .demarBottomSheet(isPresented: $showDetails) {
            if let profile = appState.selectedServer {
                ServerDetailsSheet(
                    profile: profile,
                    reachState: appState.serverReachability[profile.id] ?? .checking,
                    trafficBytes: appState.traffic?.bytesForServer(profile.displayName),
                    favorite: appState.favoriteServerIds.contains(profile.id),
                    onToggleFavorite: { appState.toggleFavoriteServer(profile.id) }
                )
            }
        }
    }

    private var activeContent: some View {
        let hasError = appState.vpnState.hasError && !appState.vpnState.isConnected
        let speedLine =
            "↓ \(ThroughputFormatter.kilobytesPerSecond(appState.downloadBps)) "
            + "↑ \(ThroughputFormatter.kilobytesPerSecond(appState.uploadBps))"

        return VStack(spacing: 0) {
            Text("Demar Proxy")
                .font(.demarTitleLarge)
                .foregroundStyle(Color.demarOnSurface)
                .frame(maxWidth: .infinity)

            // Android HomeScreen: Spacer weight 1.25 above / 1 below center block.
            HomeWeightedCenter {
                VStack(spacing: 0) {
                    VpnMainToggle(
                        state: appState.vpnState,
                        hasError: hasError,
                        onTap: { Task { await handleToggle() } }
                    )
                    Spacer().frame(height: 20)
                    Group {
                        if let profile = appState.selectedServer {
                            SelectedServerLabel(
                                profile: profile,
                                favorite: appState.favoriteServerIds.contains(profile.id)
                            ) { showDetails = true }
                            .fixedSize()
                        } else {
                            Text(String(localized: "Not selected"))
                                .font(.demarTitleMediumBold)
                                .foregroundStyle(Color.demarOnSurface)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer().frame(height: 6)
                    Text(speedLine)
                        .font(.demarBodyMedium)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .lineSpacing(1.25)
                }
            }
        }
        .padding(16)
        .task(id: isActive) {
            guard isActive else { return }
            await appState.runHomeThroughputSampling()
        }
    }

    private func handleToggle() async {
        if appState.vpnState.isConnected || appState.vpnState == .connecting {
            await appState.toggleVpn()
            return
        }
        guard appState.selectedServer != nil else {
            if !appState.isSignedIn {
                onNeedSignIn?()
            }
            return
        }
        if appState.isTrafficConnectBlocked() {
            appState.openTrafficOrFreeAlert()
            return
        }
        guard appState.selectedServer?.canConnect == true else {
            snackBar.showWarning(String(localized: "Connecting is unavailable for the Review account"))
            return
        }
        await appState.toggleVpn()
    }
}

/// Flex space above/below content split 1.25 : 1 (parity Android HomeScreen weights).
private struct HomeWeightedCenter: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let top = max(0, bounds.height - size.height) * (1.25 / 2.25)
        let x = bounds.minX + (bounds.width - size.width) / 2
        child.place(at: CGPoint(x: x, y: bounds.minY + top), proposal: ProposedViewSize(size))
    }
}

private struct SelectedServerLabel: View {
    let profile: ServerProfile
    let favorite: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                CountryFlagView(code: profile.countryCode, emoji: profile.flagEmoji)
                Spacer().frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.titleName)
                        .font(.demarTitleMediumBold)
                        .foregroundStyle(Color.demarOnSurface)
                        .lineLimit(1)
                    if let city = profile.city, !city.isEmpty {
                        Text(city)
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 120, alignment: .leading)
                Spacer().frame(width: 12)
                Rectangle()
                    .fill(Color.demarOutline.opacity(0.35))
                    .frame(width: 1, height: 52)
                Spacer().frame(width: 12)
                ServerHomeBadgeGrid(profile: profile, favorite: favorite)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }
}
