import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AppPlatform {
    static var label: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "Apple"
        #endif
    }

    /// CS API `channel` — writable only for tickets opened on this platform.
    static var supportChannel: String {
        #if os(iOS)
        "ios"
        #elseif os(macOS)
        "macos"
        #else
        "apple"
        #endif
    }

    static var versionEndpointURL: URL {
        let path: String
        #if os(iOS)
        path = "ios/version"
        #elseif os(macOS)
        path = "macos/version"
        #else
        path = "apple/version"
        #endif
        return AuthApi.vpnAPIBaseURL.appendingPathComponent(path)
    }

    static func openTestFlight() {
        guard let testFlightURL = URL(string: "itms-beta://testflight.apple.com/"),
              let appStoreURL = URL(string: "https://apps.apple.com/us/app/testflight/id899247664")
        else { return }
        #if os(iOS)
        let app = UIApplication.shared
        guard app.canOpenURL(testFlightURL) else {
            app.open(appStoreURL)
            return
        }
        app.open(testFlightURL) { opened in
            if !opened {
                app.open(appStoreURL)
            }
        }
        #elseif os(macOS)
        if !NSWorkspace.shared.open(testFlightURL) {
            NSWorkspace.shared.open(appStoreURL)
        }
        #endif
    }

    static func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}
