import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState
    var snackBar: SnackBarController

    @State private var section: DemarSection? = .home
    @State private var showLogin = false
    @State private var loginReturn: DemarSection = .account
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            #if os(macOS)
            macRoot
            #else
            iosRoot
                .accountFlowSheets(appState: appState, snackBar: snackBar)
                .demarSnackBar(snackBar)
            #endif
        }
        .loginSheet(isPresented: $showLogin) {
            Task {
                await appState.onAuthSuccess()
                section = loginReturn
            }
        }
        .alert(
            String(localized: "Update the app."),
            isPresented: $appState.shouldShowUpdateAlert
        ) {
            Button(String(localized: "Later"), role: .cancel) {
                appState.dismissUpdateAlert()
            }
            Button(String(localized: "Update")) {
                AppPlatform.openTestFlight()
                appState.dismissUpdateAlert()
            }
        } message: {
            Text(String(
                format: String(localized: "You can update the app from %@ to %@."),
                appState.appVersionDetailLabel,
                appState.actualVersionLabel
            ))
        }
        .task { await appState.bootstrapAuth() }
        .task(id: scenePhase) { await handleScenePhase() }
        .onChange(of: section) { previous, newValue in
            guard let target = newValue, needsAuth(target), !appState.isSignedIn else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { section = previous ?? .home }
            openLogin(returnTo: target)
        }
        .onChange(of: appState.isSignedIn) { _, signedIn in
            if !signedIn {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { section = .home }
            }
        }
        .onChange(of: appState.authCallbackTick) { _, tick in
            guard tick > 0, appState.isSignedIn else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                showLogin = false
                section = loginReturn
            }
        }
        .onChange(of: appState.settingsRouteRequestTick) { _, tick in
            guard tick > 0 else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { section = .settings }
        }
        .onChange(of: appState.accountRouteRequestTick) { _, tick in
            guard tick > 0 else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { section = .account }
        }
    }

    #if os(macOS)
    private var macRoot: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(DemarSection.main, id: \.self, selection: $section) { sidebarRow($0) }
                    .listStyle(.sidebar)
                Spacer(minLength: 8)
                List(selection: $section) { sidebarRow(.account) }
                    .listStyle(.sidebar)
                    .frame(height: 44)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 170, max: 170)
        } detail: {
            NavigationStack {
                screen(section ?? .home, active: true)
                    .demarMacWindowTitle(section ?? .home)
            }
            .id(section ?? .home)
            .accountFlowSheets(appState: appState, snackBar: snackBar)
            .demarSnackBarDetailAnchor()
        }
        .tint(Color.demarPrimary)
        .demarSnackBar(snackBar)
    }

    private func sidebarRow(_ item: DemarSection) -> some View {
        Label(item.title, systemImage: item.sidebarIcon)
            .tag(item)
    }
    #endif

    #if os(iOS)
    private var iosRoot: some View {
        TabView(selection: $section) {
            ForEach(DemarSection.main + [.account]) { item in
                Tab(item.title, systemImage: item.tabIcon(selected: section == item), value: item) {
                    iosTab(item)
                }
            }
        }
        .tint(Color.demarPrimary)
    }

    private func iosTab(_ item: DemarSection) -> some View {
        let active = section == item
        return Group {
            if item == .settings || item == .account || item == .servers {
                NavigationStack { screen(item, active: active) }
            } else {
                screen(item, active: active)
            }
        }
    }
    #endif

    private func needsAuth(_ section: DemarSection) -> Bool {
        section == .servers || section == .account
    }

    private func openLogin(returnTo: DemarSection) {
        loginReturn = returnTo
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showLogin = true }
    }

    private func handleScenePhase() async {
        if scenePhase == .active {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, scenePhase == .active else { return }
            appState.syncVpnStatusFromSystem()
            appState.presentCachedUpdateAlertIfNeeded()
            appState.evaluateSubscriptionAlerts()
            appState.refreshVersion()
            appState.setAppActive(true)
            #if os(iOS)
            await IDFATracking.promptIfNeeded()
            #endif
        } else {
            appState.rearmUpdateAlertForNextActive()
            appState.setAppActive(false)
        }
    }

    @ViewBuilder
    private func screen(_ section: DemarSection, active: Bool) -> some View {
        Group {
            switch section {
            case .home:
                HomeView(appState: appState, isActive: active, snackBar: snackBar) {
                    openLogin(returnTo: .servers)
                }
            case .servers:
                ServersView(
                    appState: appState,
                    isActive: active,
                    snackBar: snackBar,
                    onNeedSignIn: { openLogin(returnTo: .servers) }
                )
            case .settings:
                SettingsView(
                    appState: appState,
                    isActive: active,
                    snackBar: snackBar,
                    onNeedSignIn: { openLogin(returnTo: .settings) }
                )
            case .account:
                AccountView(
                    appState: appState,
                    isActive: active,
                    snackBar: snackBar,
                    onNeedSignIn: { openLogin(returnTo: .account) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.demarSurface)
    }
}

private extension View {
    /// Account / pay sheets. On macOS attach to the split detail so width matches traffic overlays.
    func accountFlowSheets(appState: AppState, snackBar: SnackBarController) -> some View {
        demarBottomSheet(isPresented: appState.accountSheetBinding { if case .payResult = $0 { true } else { false } }) {
            if case .payResult(let result) = appState.accountSheet {
                PayResultSheet(success: result == .success, onDismiss: appState.dismissAccountSheet)
            }
        }
        .demarBottomSheet(isPresented: appState.accountSheetBinding { if case .plans = $0 { true } else { false } }) {
            PlanCompareSheet(onBuy: { appState.openCheckout(.buy) })
        }
        .demarBottomSheet(isPresented: appState.accountSheetBinding { if case .checkout = $0 { true } else { false } }) {
            if case .checkout(let intent) = appState.accountSheet {
                SubscriptionCheckoutSheet(
                    appState: appState,
                    snackBar: snackBar,
                    intent: intent,
                    onDismiss: appState.dismissAccountSheet
                )
            }
        }
        .demarBottomSheet(isPresented: appState.accountSheetBinding { if case .alert = $0 { true } else { false } }) {
            if case .alert(let kind) = appState.accountSheet {
                SubscriptionInfoSheet(
                    kind: kind,
                    highlight: appState.subscriptionAlertHighlight(for: kind),
                    onAction: {
                        appState.dismissAccountSheet()
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            appState.openCheckout(kind == .expiry ? .renew : .buy)
                        }
                    }
                )
            }
        }
        .demarBottomSheet(isPresented: appState.accountSheetBinding { if case .traffic = $0 { true } else { false } }) {
            TrafficBottomSheet(appState: appState)
        }
    }
}
