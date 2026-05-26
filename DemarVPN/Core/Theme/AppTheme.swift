#if os(iOS)
import UIKit

enum AppTheme {
    static func configureAppearance() {
        let surface = UIColor(Demar.Color.background)
        let onSurface = UIColor(Demar.Color.label)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = surface
        nav.titleTextAttributes = [.foregroundColor: onSurface]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        if #unavailable(iOS 26.0) {
            let tab = UITabBarAppearance()
            tab.configureWithOpaqueBackground()
            tab.backgroundColor = surface
            UITabBar.appearance().standardAppearance = tab
            UITabBar.appearance().scrollEdgeAppearance = tab
        }
    }
}
#else
enum AppTheme {
    static func configureAppearance() {}
}
#endif
