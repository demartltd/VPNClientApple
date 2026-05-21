import Foundation

enum BundledXrayVersion {
    static var label: String {
        for subdirectory in ["Shared/xray", "xray", "xray_macos"] {
            if let url = Bundle.main.url(forResource: "bundled_version", withExtension: "txt", subdirectory: subdirectory),
               let raw = try? String(contentsOf: url, encoding: .utf8)
            {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "—"
    }
}
