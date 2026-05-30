import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController

    @State private var showAppSettings = false
    @State private var showServiceMenu = false
    @State private var serviceMenuTapCount = 0
    @State private var serviceMenuTapResetTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isActive {
                ScrollView {
                    VStack(spacing: 0) {
                        settingsHeader
                        Spacer().frame(height: 32)
                        SettingsLinksStrip()
                        Spacer().frame(height: 32)

                        VStack(spacing: 12) {
                            ForEach(SettingsMenuItem.all) { item in
                                SettingsActionButton(
                                    systemImage: item.systemImage,
                                    title: item.title,
                                    subtitle: item.subtitle,
                                    action: { perform(item) }
                                )
                            }
                        }

                        Spacer().frame(height: 36)
                        versionFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                    .padding(.bottom, 20)
                }
                .demarScrollScreen()
                .navigationDestination(isPresented: $showAppSettings) { AppSettingsView() }
                .navigationDestination(isPresented: $showServiceMenu) {
                    ServiceMenuView(appState: appState, snackBar: snackBar)
                }
            } else {
                Color.clear
            }
        }
        .background(Color.demarSurface)
        #if os(iOS)
        .demarNavigationRoot(backHistoryLabel: "Настройки")
        #endif
    }

    private func perform(_ item: SettingsMenuItem) {
        switch item {
        case .appSettings: showAppSettings = true
        case .invite: snackBar.showInfo("Demar VPN — клиент VLESS/Sing-box.")
        case .feedback, .terms, .privacy: snackBar.showInfo("Скоро")
        }
    }

    private var settingsHeader: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.demarPrimary)
            Text("Demar VPN")
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
            Text("Настройки подключения и приложения")
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var versionFooter: some View {
        Button(action: onVersionFooterTap) {
            VStack(spacing: 2) {
                Text("Demar VPN - \(appState.appVersionLabel) - \(AppPlatform.label)")
                Text(appState.coreVersionToken.isEmpty ? "core - …" : "core - \(appState.coreVersionToken)")
            }
            .font(.demarBodySmall)
            .foregroundStyle(Color.demarOnSurface.opacity(0.50))
            .multilineTextAlignment(.center)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func onVersionFooterTap() {
        serviceMenuTapResetTask?.cancel()
        serviceMenuTapCount += 1
        if serviceMenuTapCount >= 3 {
            serviceMenuTapCount = 0
            showServiceMenu = true
            return
        }
        serviceMenuTapResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await MainActor.run { serviceMenuTapCount = 0 } }
        }
    }
}

private enum SettingsMenuItem: String, CaseIterable, Identifiable {
    case appSettings, feedback, invite, terms, privacy

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appSettings: "gearshape.2"
        case .feedback: "star.bubble"
        case .invite: "square.and.arrow.up"
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        }
    }

    var title: String {
        switch self {
        case .appSettings: "Настройки приложения"
        case .feedback: "Обратная связь"
        case .invite: "Пригласите друзей по ссылке"
        case .terms: "Условия использования"
        case .privacy: "Конфиденциальность"
        }
    }

    var subtitle: String {
        switch self {
        case .appSettings: "Подключение, журнал диагностики и статус функций"
        case .feedback: "Отправить ошибку или предложение"
        case .invite: "Получите бесплатный премиум"
        case .terms: "Правила использования сервиса"
        case .privacy: "Как обрабатываются данные"
        }
    }

    static var all: [SettingsMenuItem] { allCases }
}
