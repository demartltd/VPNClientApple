import SwiftUI

@main
struct DemarVPNApp: App {
    @State private var appState = AppState()
    @State private var snackBar = SnackBarController()

    init() {
        FontAwesomeBrands.register()
        AppTheme.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState, snackBar: snackBar)
                .preferredColorScheme(.dark)
                .demarSnackBar(snackBar)
        }
        #if os(macOS)
        Window("Свои проверки", id: CustomEgressProbesWindow.id) {
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
