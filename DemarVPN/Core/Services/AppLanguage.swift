import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// App language preference.
///
/// iOS: system per-app language (`Bundle.preferredLocalizations`) — do not override `AppleLanguages`.
/// macOS: in-app picker persists `AppleLanguages` and relaunches (Language & Region takes effect after relaunch).
@Observable
final class AppLanguage {
    static let shared = AppLanguage()
    static let supported = [
        "en", "ru", "uk", "tr", "uz",
        "zh-Hans", "zh-Hant", "ko", "ja",
        "es", "de", "fr", "hi",
    ]

    private(set) var code: String

    var displayName: String { Self.displayName(for: code) }

    private init() {
        #if os(iOS)
        code = Self.bundleCode()
        #else
        let resolved = Self.resolveCode()
        Self.persist(resolved)
        code = resolved
        #endif
    }

    static func displayName(for code: String) -> String {
        let locale = Locale.current
        let raw = locale.localizedString(forIdentifier: code)
            ?? locale.localizedString(forLanguageCode: Locale(identifier: code).language.languageCode?.identifier ?? code)
            ?? code
        guard let first = raw.first else { return raw }
        return String(first).uppercased(with: locale) + raw.dropFirst()
    }

    /// Canonical code from `supported`, or nil.
    static func match(_ raw: String) -> String? {
        Bundle.preferredLocalizations(from: supported, forPreferences: [raw]).first
    }

    #if os(macOS)
    func select(_ code: String) {
        guard let next = Self.match(code), next != self.code else { return }
        Self.persist(next)
        self.code = next
        Self.relaunch()
    }
    #endif

    static func openSystemLanguageSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private static func bundleCode() -> String {
        match(Bundle.main.preferredLocalizations.first ?? "en") ?? "en"
    }

    #if os(macOS)
    private static let defaultsKey = "demar_app_language"

    private static func resolveCode() -> String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           let hit = match(stored)
        {
            return hit
        }
        if let apple = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first,
           let hit = match(apple)
        {
            return hit
        }
        return bundleCode()
    }

    private static func persist(_ code: String) {
        UserDefaults.standard.set(code, forKey: defaultsKey)
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }

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
