import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState
    var snackBar: SnackBarController

    @State private var section: DemarSection? = .home
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        #if os(macOS)
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
        #else
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, scenePhase == .active else { return }
            appState.syncVpnStatusFromSystem()
            await IDFATracking.promptIfNeeded()
        }
        #endif
    }

    #if os(macOS)
    private func sidebarRow(_ item: DemarSection) -> some View {
        Label(item.title, systemImage: item.sidebarIcon)
            .tag(item)
    }
    #endif

    #if os(iOS)
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

    @ViewBuilder
    private func screen(_ section: DemarSection, active: Bool) -> some View {
        Group {
            switch section {
            case .home:
                HomeView(appState: appState, isActive: active)
            case .servers:
                ServersView(appState: appState, isActive: active, snackBar: snackBar)
            case .settings:
                SettingsView(appState: appState, isActive: active, snackBar: snackBar)
            case .account:
                AccountView(appState: appState, isActive: active, snackBar: snackBar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.demarSurface)
    }
}
