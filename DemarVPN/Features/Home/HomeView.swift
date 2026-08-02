import SwiftUI

struct HomeView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    var onNeedSignIn: (() -> Void)?

    var body: some View {
        Group {
            if isActive {
                activeContent
            } else {
                Color.clear
            }
        }
    }

    private var activeContent: some View {
        let hasError = appState.vpnState.hasError && !appState.vpnState.isConnected
        let speedLine =
            "↓ \(ThroughputFormatter.kilobytesPerSecond(appState.downloadBps)) "
            + "↑ \(ThroughputFormatter.kilobytesPerSecond(appState.uploadBps))"

        return VStack(spacing: 0) {
            Text("Demar VPN")
                .font(.demarTitleLarge)
                .foregroundStyle(Color.demarOnSurface)
                .frame(maxWidth: .infinity)

            Spacer()

            VpnMainToggle(
                state: appState.vpnState,
                hasError: hasError,
                onTap: {
                    Task { await handleToggle() }
                }
            )

            Spacer().frame(height: 20)

            Text(appState.selectedServer?.listTitle ?? String(localized: "Not selected"))
                .font(.demarTitleMediumBold)
                .foregroundStyle(Color.demarOnSurface)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 6)

            Text(speedLine)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .lineSpacing(1.25)

            Spacer()
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
        if appState.selectedServer == nil {
            if !appState.isSignedIn {
                onNeedSignIn?()
            }
            return
        }
        guard appState.selectedServer?.canConnect == true else {
            snackBar.showWarning(String(localized: "Connecting is unavailable for the Review account"))
            return
        }
        await appState.toggleVpn()
    }
}
