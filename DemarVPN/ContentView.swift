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
        }
        .tint(Color.demarPrimary)
    }

    private func sidebarRow(_ item: DemarSection) -> some View {
        Label(item.title, systemImage: item.sidebarIcon)
            .tag(item)
    }
    #endif

    #if os(iOS)
    private var iosRoot: some View {
        TabView(selection: $section) {
            ForEach(DemarSection.main) { item in
                Tab(item.title, systemImage: item.tabIcon(selected: section == item), value: item) {
                    iosTab(item)
                }
            }
            Tab(value: DemarSection.account, role: .search) {
                iosTab(.account)
            } label: {
                Image(systemName: DemarSection.account.tabIcon(selected: section == .account))
                    .accessibilityLabel(DemarSection.account.title)
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
            appState.refreshVersionIfNeeded()
            #if os(macOS)
            appState.setAppActive(true)
            #endif
            #if os(iOS)
            await IDFATracking.promptIfNeeded()
            #endif
        } else {
            appState.rearmUpdateAlertForNextActive()
            #if os(macOS)
            appState.setAppActive(false)
            #endif
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
