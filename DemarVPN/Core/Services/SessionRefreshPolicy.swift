import Foundation

enum SessionRefreshPolicy {
    static let ttl: TimeInterval = 600

    static func isStale(since last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= ttl
    }
}
