import Foundation
import Observation

struct JournalLine: Identifiable, Equatable {
    let id: UUID
    let text: String
}

@Observable
final class AppLog {
    static let shared = AppLog()

    private(set) var lines: [JournalLine] = []

    var isEmpty: Bool { lines.isEmpty }

    /// Newest-first, for the on-screen journal panel.
    var panelText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    private init() {
        #if os(macOS)
        append("[app] Demar VPN macOS (SwiftUI) started")
        #else
        append("[app] Demar VPN iOS (SwiftUI) started")
        #endif
    }

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isCoreTrafficAccessNoise(trimmed) else { return }
        let sanitized = Self.redactIPAddresses(in: trimmed)
        guard !containsEquivalentLine(sanitized) else { return }

        let text: String
        text = DemarLogTime.looksPreStamped(sanitized)
            ? sanitized
            : DemarLogTime.journalLine(sanitized)
        lines.insert(JournalLine(id: UUID(), text: text), at: 0)
        if lines.count > VpnSharedStore.journalMaxLines {
            lines.removeLast(lines.count - VpnSharedStore.journalMaxLines)
        }
    }

    /// Skips duplicate journal lines (pending drain mirrors the same text into the journal).
    private func containsEquivalentLine(_ line: String) -> Bool {
        let key = Self.lineEquivalenceKey(line)
        guard !key.isEmpty else { return false }
        return lines.contains { Self.lineEquivalenceKey($0.text) == key }
    }

    private static func lineEquivalenceKey(_ line: String) -> String {
        DemarLogTime.messageBody(in: line)
    }

    /// Imports new lines from the App Group VPN journal (extension + host).
    func importSharedJournal() {
        for line in VpnSharedStore.readIncrementalJournalLines() where !line.isEmpty {
            append(line)
        }
    }

    /// Masks IP addresses for the UI journal (IPv4: `***.***.111.111`; IPv6: `***::tail`).
    static func redactIPAddresses(in line: String) -> String {
        redactIPv6(in: redactIPv4(in: line))
    }

    /// Core access log lines (per-connection traffic) — too noisy for the app journal.
    static func isCoreTrafficAccessNoise(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains(" accepted "),
              s.contains(" from "),
              s.contains("->"),
              s.contains("]")
        else { return false }
        let lower = s.lowercased()
        return lower.contains("tcp:") || lower.contains("udp:")
    }

    // Swift Regex has no lookbehind/lookahead — boundaries checked in replace closures.
    private static let ipv4Regex = #/(?:\d{1,3}\.){3}\d{1,3}/#
    private static let ipv6Regex = #/(?:(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4}|(?:[0-9a-fA-F]{1,4}:)*::(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{0,4})/#

    private static func redactIPv4(in line: String) -> String {
        line.replacing(ipv4Regex) { match in
            let raw = String(match.output)
            guard isPlausibleIPv4(raw),
                  hasIPv4Boundaries(line, range: match.range)
            else { return raw }
            return maskIPv4(raw)
        }
    }

    private static func redactIPv6(in line: String) -> String {
        line.replacing(ipv6Regex) { match in
            let raw = String(match.output)
            guard isPlausibleIPv6(raw),
                  hasIPv6Boundaries(line, range: match.range)
            else { return raw }
            return maskIPv6(raw)
        }
    }

    private static func hasIPv4Boundaries(_ line: String, range: Range<String.Index>) -> Bool {
        if range.lowerBound > line.startIndex {
            let before = line[line.index(before: range.lowerBound)]
            if before.isNumber { return false }
        }
        if range.upperBound < line.endIndex {
            let after = line[range.upperBound]
            if after.isNumber { return false }
        }
        return true
    }

    private static func hasIPv6Boundaries(_ line: String, range: Range<String.Index>) -> Bool {
        let adjacent = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:"))
        if range.lowerBound > line.startIndex {
            let before = line[line.index(before: range.lowerBound)]
            if before.unicodeScalars.allSatisfy({ adjacent.contains($0) }) { return false }
        }
        if range.upperBound < line.endIndex {
            let after = line[range.upperBound]
            if after.unicodeScalars.allSatisfy({ adjacent.contains($0) }) { return false }
        }
        return true
    }

    private static func maskIPv4(_ raw: String) -> String {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return raw }
        return "***.***.\(parts[2]).\(parts[3])"
    }

    private static func maskIPv6(_ raw: String) -> String {
        guard let lastColon = raw.lastIndex(of: ":") else { return "***" }
        let tail = raw[raw.index(after: lastColon)...]
        if raw.contains("::") {
            return "***::\(tail)"
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return "***" }
        let masked = Array(repeating: "***", count: parts.count - 1).joined(separator: ":")
        return "\(masked):\(tail)"
    }

    private static func isPlausibleIPv4(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy(isIPv4Octet)
    }

    private static func isPlausibleIPv6(_ raw: String) -> Bool {
        guard raw.contains(":"), raw.count <= 45 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isIPv4Octet(_ part: Substring) -> Bool {
        guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
        return (0 ... 255).contains(value)
    }

    func clear() {
        lines.removeAll()
        append("[app] journal cleared")
    }

    var joinedText: String {
        lines.reversed().map(\.text).joined(separator: "\n")
    }

    /// Temp `.txt` for the system share sheet (file only, no plain-text attachment).
    func exportFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportFileName())
        try? joinedText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func exportFileName() -> String {
        DemarLogTime.exportFileName()
    }
}
