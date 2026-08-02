import SwiftUI

struct AccountView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    var onNeedSignIn: (() -> Void)?

    @State private var signingOut = false

    var body: some View {
        Group {
            if isActive {
                ScrollView {
                    VStack(spacing: 32) {
                        header
                        if let session = appState.authSession {
                            signedIn(session)
                        } else {
                            guestCTA
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                    .padding(.bottom, 20)
                }
                .demarScrollScreen()
            } else {
                Color.clear
            }
        }
        .background(Color.demarSurface)
        #if os(iOS)
        .demarNavigationRoot(backHistoryLabel: String(localized: "Account"))
        #endif
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: appState.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.demarPrimary)
            Text(appState.authSession?.username ?? String(localized: "Account"))
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
            Text(
                appState.authSession.map { String(localized: "ID: \($0.userId)") }
                    ?? String(localized: "Sign in to sync your subscription and servers")
            )
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func signedIn(_ session: AuthSession) -> some View {
        VStack(spacing: 12) {
            SectionCard(title: String(localized: "Subscription"), subtitle: nil) {
                DemarKvRow(key: String(localized: "Plan"), value: session.vpnSubscription ?? "—")
                if let exp = formatExpiry(session.vpnExpiresAt) {
                    DemarKvRow(key: String(localized: "Expires"), value: exp)
                }
            }
            SettingsActionButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: signingOut ? String(localized: "Signing out…") : String(localized: "Sign out"),
                subtitle: String(localized: "End session on this device"),
                action: {
                    guard !signingOut else { return }
                    signingOut = true
                    Task {
                        defer { signingOut = false }
                        do {
                            try await appState.signOut()
                            snackBar.showInfo(String(localized: "You signed out"))
                        } catch {
                            snackBar.showError(String(localized: "Couldn’t sign out. Try again"))
                        }
                    }
                }
            )
            .disabled(signingOut)
            .opacity(signingOut ? 0.55 : 1)
        }
    }

    private var guestCTA: some View {
        SettingsActionButton(
            systemImage: "arrow.right.circle.fill",
            title: String(localized: "Sign in"),
            subtitle: String(localized: "Sync subscription and servers"),
            action: { onNeedSignIn?() }
        )
    }

    private func formatExpiry(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFrac.date(from: raw) ?? plain.date(from: raw) else {
            return String(localized: "Until \(raw)")
        }
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return String(localized: "Until \(f.string(from: date))")
    }
}
