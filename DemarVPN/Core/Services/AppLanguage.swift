import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AppLanguage {
    static var currentDisplayName: String {
        let code = Bundle.main.preferredLocalizations.first.map {
            String($0.prefix(2)).lowercased()
        } ?? "en"
        let raw = Locale.current.localizedString(forLanguageCode: code)
            ?? Locale(identifier: code).localizedString(forLanguageCode: code)
            ?? code
        guard let first = raw.first else { return raw }
        return String(first).uppercased(with: .current) + raw.dropFirst()
    }

    static func openSystemLanguageSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Localization.prefPane"))
        }
        #endif
    }
}
