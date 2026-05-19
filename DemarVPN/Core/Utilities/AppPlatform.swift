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
}
