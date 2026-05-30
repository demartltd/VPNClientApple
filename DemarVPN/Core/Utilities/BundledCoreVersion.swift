import Foundation

enum BundledCoreVersion {
    static var label: String {
        for sub in CoreBundleAssets.subdirectories {
            if let url = Bundle.main.url(forResource: "bundled_version", withExtension: "txt", subdirectory: sub),
               let raw = try? String(contentsOf: url, encoding: .utf8)
            {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "—"
    }
}
