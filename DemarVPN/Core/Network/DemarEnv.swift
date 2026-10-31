import Foundation

/// API bases from bundled `demar.env` (copy of repo-root `.env`) or process env.
enum DemarEnv {
    static let authAPIBase = url("DEMAR_AUTH_API_BASE")
    static let vpnAPIBase = url("DEMAR_VPN_API_BASE")
    static let accountAPIBase = url("DEMAR_ACCOUNT_API_BASE")
    static let supportAPIBase = url("DEMAR_SUPPORT_API_BASE")

    private static func url(_ key: String) -> URL {
        guard let raw = value(key), let url = URL(string: raw), !raw.isEmpty else {
            fatalError("DemarEnv: missing \(key) — copy .env.example → .env and demar.env into Resources")
        }
        return url
    }

    private static func value(_ key: String) -> String? {
        if let e = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return e
        }
        return dotenv[key]
    }

    private static let dotenv: [String: String] = {
        guard let url = Bundle.main.url(forResource: "demar", withExtension: "env"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var map: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !k.isEmpty { map[k] = v }
        }
        return map
    }()
}
