import Foundation

enum BundledCoreVersion {
    static var label: String {
        guard let url = CoreBundleAssets.bundledURL(for: "bundled_version.txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return "—" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}
