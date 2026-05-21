import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState
    var snackBar: SnackBarController

    @State private var selectedTab = 0
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            tabShell(tag: 0) {
                HomeView(appState: appState, isActive: selectedTab == 0)
            }
            .tabItem {
                Label("Главная", systemImage: selectedTab == 0 ? "shield.fill" : "shield")
            }

            tabShell(tag: 1) {
                ServersView(appState: appState, isActive: selectedTab == 1, snackBar: snackBar)
            }
            .tabItem {
                Label("Сервера", systemImage: "globe")
            }

            tabShell(tag: 2) {
                NavigationStack {
                    SettingsView(
                        appState: appState,
                        isActive: selectedTab == 2,
                        snackBar: snackBar
                    )
                }
            }
            .tabItem {
                Label("Настройки", systemImage: selectedTab == 2 ? "gearshape.fill" : "gearshape")
            }
        }
        .tint(Color.demarPrimary)
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            appState.syncVpnStatusFromSystem()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            appState.syncVpnStatusFromSystem()
            await IDFATracking.promptIfNeeded()
        }
        #endif
    }

    @ViewBuilder
    private func tabShell<Content: View>(tag: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.demarSurface)
            .tag(tag)
    }
}
