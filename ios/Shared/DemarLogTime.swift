import Foundation

/// Journal timestamps: `2026-06-27-14-30-45` (UTC, no fractional seconds).
enum DemarLogTime {
  private static let stampLength = 19

  private static let journal: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    return f
  }()

  static func stamp(_ date: Date = Date()) -> String { journal.string(from: date) }

  static func journalLine(_ message: String, date: Date = Date()) -> String {
    "\(stamp(date)) \(message)"
  }

  static func exportFileName(prefix: String = "demar-vpn-journal") -> String {
    "\(prefix)-\(stamp()).txt"
  }

  static func parseStamp(_ raw: String) -> Date? {
    journal.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func looksPreStamped(_ line: String) -> Bool {
    leadingStamp(in: line) != nil
  }

  static func leadingStamp(in line: String) -> String? {
    let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count > stampLength + 1 else { return nil }
    let prefix = String(s.prefix(stampLength))
    guard s[s.index(s.startIndex, offsetBy: stampLength)] == " ", parseStamp(prefix) != nil else { return nil }
    return prefix
  }

  static func messageBody(in line: String) -> String {
    let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let stamp = leadingStamp(in: s) else { return s }
    return String(s.dropFirst(stamp.count + 1))
  }
}
