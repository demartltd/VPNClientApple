import SwiftUI

struct HomeView: View {
    @Bindable var appState: AppState
    let isActive: Bool

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
                onTap: appState.canToggleVpn
                    ? { Task { await appState.toggleVpn() } }
                    : nil
            )

            Spacer().frame(height: 20)

            Text(appState.selectedServer?.displayName ?? "Не выбран")
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
        #if os(iOS)
        .task(id: isActive) {
            guard isActive else { return }
            await appState.runHomeThroughputSampling()
        }
        #endif
    }
}
