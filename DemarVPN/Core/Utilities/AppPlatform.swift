import Foundation

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
}
