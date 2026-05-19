import Foundation
import Observation

@Observable
final class AppLog {
    static let shared = AppLog()

    private(set) var lines: [String] = []

    private init() {
        append("[app] Demar VPN iOS (SwiftUI) started")
    }

    func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.insert("[\(stamp)] \(line)", at: 0)
        if lines.count > 500 {
            lines.removeLast(lines.count - 500)
        }
    }

    func clear() {
        lines.removeAll()
        append("[app] journal cleared")
    }

    var joinedText: String {
        lines.reversed().joined(separator: "\n")
    }
}
