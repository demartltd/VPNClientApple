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
            List(DemarSection.allCases, id: \.self, selection: $section) { item in
                Label(item.title, systemImage: item.sidebarIcon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 170, max: 170)
        } detail: {
            screen(section ?? .home, active: true)
                .id(section ?? .home)
        }
        .tint(Color.demarPrimary)
        #else
        TabView(selection: $section) {
            ForEach(DemarSection.allCases) { item in
                screen(item, active: section == item)
                    .tabItem { Label(item.title, systemImage: item.tabIcon(selected: section == item)) }
                    .tag(item)
            }
        }
        .tint(Color.demarPrimary)
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
    private func screen(_ section: DemarSection, active: Bool) -> some View {
        Group {
            switch section {
            case .home:
                HomeView(appState: appState, isActive: active)
            case .servers:
                ServersView(appState: appState, isActive: active, snackBar: snackBar)
            case .settings:
                NavigationStack {
                    SettingsView(appState: appState, isActive: active, snackBar: snackBar)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.demarSurface)
    }
}
