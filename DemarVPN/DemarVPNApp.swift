import SwiftUI

@main
struct DemarVPNApp: App {
    @State private var appState = AppState()
    @State private var snackBar = SnackBarController()

    init() {
        // Apply stored AppleLanguages before UI reads Bundle localizations.
        _ = AppLanguage.shared
        FontAwesomeBrands.register()
        AppTheme.configureAppearance()
    }

    var body: some Scene {
        #if os(macOS)
        macScenes
        #else
        WindowGroup { rootContent }
        #endif
    }

    #if os(macOS)
    @SceneBuilder
    private var macScenes: some Scene {
        // Reuse existing main window for demarvpn://; hide File → New Window.
        WindowGroup {
            rootContent
                .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window(String(localized: "Custom checks"), id: CustomEgressProbesWindow.id) {
            CustomEgressProbesPanel()
                .preferredColorScheme(.dark)
                .customEgressProbesMacWindowFrame()
        }
        .defaultSize(
            width: CustomEgressProbesWindow.width,
            height: CustomEgressProbesWindow.height
        )
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
    #endif

    @ViewBuilder
    private var rootContent: some View {
        ContentView(appState: appState, snackBar: snackBar)
            .preferredColorScheme(.dark)
            .demarSnackBar(snackBar)
            #if os(iOS)
            .demarDynamicIslandBadge()
            #endif
            .onOpenURL { url in
                Task { await appState.consumeIncomingURL(url) }
            }
    }
}
