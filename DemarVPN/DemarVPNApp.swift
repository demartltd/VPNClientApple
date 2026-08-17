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
        WindowGroup {
            ContentView(appState: appState, snackBar: snackBar)
                .preferredColorScheme(.dark)
                .demarSnackBar(snackBar)
                #if os(iOS)
                .demarDynamicIslandBadge()
                #endif
                .onOpenURL { url in
                    Task { await appState.consumeAuthCallback(url) }
                }
        }
        #if os(macOS)
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
        #endif
    }
}
