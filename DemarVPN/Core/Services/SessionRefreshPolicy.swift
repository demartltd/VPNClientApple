import Foundation

enum SessionRefreshPolicy {
    static let ttl: TimeInterval = 600
    /// After a failed refresh, skip automatic retries this long (avoids API hammer / rate-limit).
    static let failureCooldown: TimeInterval = 90

    static func isStale(since last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= ttl
    }

    /// True when the last attempt failed recently and we should not auto-retry yet.
    static func inFailureCooldown(success: Date?, attempt: Date?, now: Date = Date()) -> Bool {
        guard let attempt else { return false }
        guard now.timeIntervalSince(attempt) < failureCooldown else { return false }
        if let success, success >= attempt { return false }
        return true
    }
}
