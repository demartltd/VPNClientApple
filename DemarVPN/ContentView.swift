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
                .payFlowSheets(appState: appState, snackBar: snackBar)
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
            .payFlowSheets(appState: appState, snackBar: snackBar)
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
        .overlay(alignment: .top) {
            if appState.isRefreshingServers {
                ServersRefreshBanner()
                    .safeAreaPadding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.28), value: appState.isRefreshingServers)
    }

    private func iosTab(_ item: DemarSection) -> some View {
        let active = section == item
        return Group {
            if item == .settings || item == .account {
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
    /// Pay / compare sheets. On macOS attach to the split detail so width matches traffic overlays.
    func payFlowSheets(appState: AppState, snackBar: SnackBarController) -> some View {
        demarBottomSheet(
            isPresented: Binding(
                get: { appState.payResult != nil },
                set: { if !$0 { appState.dismissPayResult() } }
            )
        ) {
            if let result = appState.payResult {
                PayResultSheet(
                    success: result == .success,
                    onDismiss: { appState.dismissPayResult() }
                )
            }
        }
        .demarBottomSheet(
            isPresented: Binding(
                get: { appState.showPlanCompare },
                set: { appState.showPlanCompare = $0 }
            )
        ) {
            PlanCompareSheet(
                onBuy: { appState.openCheckout(.buy) }
            )
        }
        .demarBottomSheet(
            isPresented: Binding(
                get: { appState.checkoutIntent != nil },
                set: { if !$0 { appState.dismissCheckout() } }
            )
        ) {
            if let intent = appState.checkoutIntent {
                SubscriptionCheckoutSheet(
                    appState: appState,
                    snackBar: snackBar,
                    intent: intent,
                    onDismiss: { appState.dismissCheckout() }
                )
            }
        }
    }
}
