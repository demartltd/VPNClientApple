import SwiftUI

struct AccountUser: Equatable {
    let email: String
    let displayName: String
}

struct AccountView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Group {
            if isActive {
                ScrollView {
                    VStack(spacing: 32) {
                        header
                        if let user = appState.accountUser {
                            signedIn(user)
                        } else {
                            signInForm
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
            Image(systemName: appState.accountUser == nil ? "person.crop.circle" : "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.demarPrimary)
            Text(appState.accountUser?.displayName ?? "Аккаунт")
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
            Text(appState.accountUser?.email ?? "Войдите, чтобы синхронизировать подписку и сервера")
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func signedIn(_ user: AccountUser) -> some View {
        VStack(spacing: 12) {
            SectionCard(title: "Подписка", subtitle: "MVP — данные появятся после подключения API") {
                DemarKvRow(key: "Статус", value: "Активна")
            }
            SettingsActionButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: "Выйти",
                subtitle: "Завершить сеанс на этом устройстве",
                action: {
                    email = user.email
                    password = ""
                    appState.signOut()
                }
            )
        }
    }

    private var signInForm: some View {
        VStack(spacing: 12) {
            accountField("Email", text: $email, secure: false)
            accountField("Пароль", text: $password, secure: true)
            SettingsActionButton(
                systemImage: "arrow.right.circle.fill",
                title: "Войти",
                subtitle: "Синхронизация подписки и серверов",
                action: signIn
            )
            .disabled(email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1)
            SettingsActionButton(
                systemImage: "person.badge.plus",
                title: "Создать аккаунт",
                subtitle: "Регистрация нового пользователя",
                action: { snackBar.showInfo("Регистрация скоро.") }
            )
        }
    }

    private func signIn() {
        guard appState.signIn(email: email, password: password) else {
            snackBar.showInfo("Введите email и пароль.")
            return
        }
        password = ""
    }

    private func accountField(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
            }
        }
        .textFieldStyle(.plain)
        .font(.demarBodyMedium)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
        )
    }

}
