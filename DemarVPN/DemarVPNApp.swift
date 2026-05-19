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
    }
}
