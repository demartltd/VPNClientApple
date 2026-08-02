import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// App language preference.
///
/// Apple: on Mac, localization takes effect only after the app relaunches
/// (Language & Region / per-app language). We persist `AppleLanguages` and relaunch.
@Observable
final class AppLanguage {
    static let shared = AppLanguage()
    static let supported = ["en", "ru"]

    private static let defaultsKey = "demar_app_language"

    private(set) var code: String

    var displayName: String { Self.displayName(for: code) }

    private init() {
        let resolved = Self.resolveCode()
        // Keep AppleLanguages in sync so Bundle.main.preferredLocalizations matches on launch.
        Self.persist(resolved)
        code = resolved
    }

    static func displayName(for code: String) -> String {
        let raw = Locale(identifier: code).localizedString(forLanguageCode: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
        guard let first = raw.first else { return raw }
        return String(first).uppercased(with: Locale(identifier: code)) + raw.dropFirst()
    }

    func select(_ code: String) {
        let next = code.lowercased()
        guard Self.supported.contains(next), next != self.code else { return }
        Self.persist(next)
        self.code = next
        #if os(macOS)
        Self.relaunch()
        #endif
    }

    static func openSystemLanguageSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        // System Settings → Language & Region (per-app languages live here).
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private static func resolveCode() -> String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey)?.lowercased(),
           supported.contains(stored)
        {
            return stored
        }
        if let apple = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?
            .first
            .map({ String($0.prefix(2)).lowercased() }),
           supported.contains(apple)
        {
            return apple
        }
        if let preferred = Bundle.main.preferredLocalizations.first.map({
            String($0.prefix(2)).lowercased()
        }), supported.contains(preferred) {
            return preferred
        }
        return "en"
    }

    private static func persist(_ code: String) {
        UserDefaults.standard.set(code, forKey: defaultsKey)
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }

    #if os(macOS)
    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
    #endif
}
