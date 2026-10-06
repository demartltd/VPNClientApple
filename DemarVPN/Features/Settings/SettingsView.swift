import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    var onNeedSignIn: (() -> Void)?

    @State private var route: SettingsRoute?
    @State private var showDocumentsMenu = false
    @State private var serviceMenuTapCount = 0
    @State private var serviceMenuTapResetTask: Task<Void, Never>?
    @State private var supportUnread = SupportUnreadStore.shared

    @State private var showPromoInput = false
    @State private var showPromoResult = false
    @State private var promoCode = ""
    @State private var promoResultMessage = ""

    var body: some View {
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
                            unread: item == .feedback && supportUnread.hasUnread,
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
        .demarPush($route) { route in
            switch route {
            case .appSettings:
                AppSettingsView(
                    isFree: appState.isFreeSubscription,
                    onBuySubscription: buySubscription
                )
            case .tunSettings:
                TunSettingsView(
                    isFree: appState.isFreeSubscription,
                    onBuySubscription: buySubscription
                )
            case .serviceMenu(let initialRoute):
                ServiceMenuView(appState: appState, snackBar: snackBar, initialRoute: initialRoute)
            case .support(let initialRoute):
                if let session = appState.authSession {
                    SupportScreen(session: session, snackBar: snackBar, initialRoute: initialRoute)
                }
            case .document(let document):
                LegalDocumentView(document: document)
            }
        }
        .background(Color.demarSurface)
        .alert(String(localized: "Enter promo code"), isPresented: $showPromoInput) {
            TextField("DEMARFREE", text: $promoCode)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .onChange(of: promoCode) { _, new in
                    let filtered = new.uppercased().filter { $0.isLetter && $0.isASCII || $0.isNumber }
                    if filtered != new { promoCode = filtered }
                }
            Button(String(localized: "Activate")) { Task { await activatePromo() } }
            Button(String(localized: "Cancel"), role: .cancel) { promoCode = "" }
        }
        .tint(Color.white)
        .alert(promoResultMessage, isPresented: $showPromoResult) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
        .tint(Color.white)
        .documentsMenu(
            isPresented: $showDocumentsMenu,
            onSelect: { route = .document($0) }
        )
        .task(id: appState.settingsRouteRequestTick) {
            applyPendingSettingsRoute()
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            applyPendingSettingsRoute()
        }
        #if os(iOS)
        .demarNavigationRoot(backHistoryLabel: String(localized: "Settings"))
        #endif
    }

    private func buySubscription() {
        if appState.isSignedIn {
            appState.openCheckout(.buy)
        } else {
            appState.pendingAccountSheet = .buy
            onNeedSignIn?()
        }
    }

    private func perform(_ item: SettingsMenuItem) {
        switch item {
        case .appSettings: route = .appSettings
        case .documents: showDocumentsMenu = true
        case .feedback:
            if appState.isSignedIn { route = .support() } else { onNeedSignIn?() }
        case .invite:
            snackBar.showInfo(String(localized: "Coming soon"))
        case .promoCode:
            if appState.isSignedIn { showPromoInput = true } else { onNeedSignIn?() }
        }
    }

    private func activatePromo() async {
        guard let session = appState.authSession else { return }
        let code = promoCode.trimmingCharacters(in: .whitespacesAndNewlines)
        promoCode = ""
        guard !code.isEmpty else { return }
        do {
            let result = try await PromoApi.activate(
                code: code,
                userId: session.userId,
                loginAt: session.loginAt
            )
            if result.isActivated { await appState.refreshSessionData(force: true) }
            promoResultMessage = result.localizedMessage
        } catch {
            promoResultMessage = error.localizedDescription
        }
        showPromoResult = true
    }

    private var settingsHeader: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.demarPrimary)
            Text("Demar Proxy")
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
            Text("Connection and app settings")
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var versionFooter: some View {
        Button(action: onVersionFooterTap) {
            VStack(spacing: 2) {
                Text("Demar Proxy - \(appState.appVersionLabel) - \(AppPlatform.label)")
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
            route = .serviceMenu()
            return
        }
        serviceMenuTapResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await MainActor.run { serviceMenuTapCount = 0 } }
        }
    }

    private func applyPendingSettingsRoute() {
        guard isActive, let requested = appState.consumePendingSettingsRoute() else { return }
        route = requested
    }
}

private enum SettingsMenuItem: String, CaseIterable, Identifiable {
    case appSettings, feedback, invite, promoCode, documents

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appSettings: "gearshape.2"
        case .feedback: "star.bubble"
        case .invite: "square.and.arrow.up"
        case .promoCode: "tag"
        case .documents: "doc.on.doc"
        }
    }

    var title: String {
        switch self {
        case .appSettings: String(localized: "App settings")
        case .feedback: String(localized: "Support")
        case .invite: String(localized: "Invite friends")
        case .promoCode: String(localized: "Promo code")
        case .documents: String(localized: "Documents")
        }
    }

    var subtitle: String {
        switch self {
        case .appSettings: String(localized: "Connection, diagnostics journal, and feature status")
        case .feedback: String(localized: "Ask a question or get help with the app")
        case .invite: String(localized: "Get free premium")
        case .promoCode: String(localized: "Activate a subscription promo code")
        case .documents: String(localized: "Terms of use and privacy")
        }
    }

    static var all: [SettingsMenuItem] { allCases }
}
