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
        .demarNavigationRoot(backHistoryLabel: "Аккаунт")
        #endif
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: appState.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.demarPrimary)
            Text(appState.authSession?.username ?? "Аккаунт")
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
            Text(appState.authSession.map { "ID: \($0.userId)" } ?? "Войдите, чтобы синхронизировать подписку и сервера")
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func signedIn(_ session: AuthSession) -> some View {
        VStack(spacing: 12) {
            SectionCard(title: "Подписка", subtitle: nil) {
                DemarKvRow(key: "План", value: session.vpnSubscription ?? "—")
                if let exp = formatExpiry(session.vpnExpiresAt) {
                    DemarKvRow(key: "Срок", value: exp)
                }
            }
            SettingsActionButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: signingOut ? "Выход…" : "Выйти",
                subtitle: "Завершить сеанс на этом устройстве",
                action: {
                    guard !signingOut else { return }
                    signingOut = true
                    Task {
                        defer { signingOut = false }
                        do {
                            try await appState.signOut()
                            snackBar.showInfo("Вы вышли из аккаунта")
                        } catch {
                            snackBar.showError("Не удалось выйти. Попробуйте ещё раз")
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
            title: "Войти",
            subtitle: "Синхронизация подписки и серверов",
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
            return "До \(raw)"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return "До \(f.string(from: date))"
    }
}
