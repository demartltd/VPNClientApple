import Foundation

/// Cooldown / window rules for subscription upsell sheets (parity with Android).
enum SubscriptionAlertStore {
    /// FREE upsell: show after ≥200 MiB used.
    static let trafficThresholdBytes: Int64 = 200 * 1024 * 1024
    /// Early warning: from 3 days down to just above 24h.
    static let expiryEarlyMaxMs: Int64 = 72 * 60 * 60 * 1000
    static let expiryEarlyMinMs: Int64 = 24 * 60 * 60 * 1000
    /// Final warning: last 18h until expiry. Gap (18h, 24h] is silent.
    static let expiryFinalMaxMs: Int64 = 18 * 60 * 60 * 1000
    static let expiryCooldown: TimeInterval = 3 * 60 * 60
    static let trafficCooldown: TimeInterval = 6 * 60 * 60

    private enum Key {
        static let expiryAt = "demar_sub_alert_expiry_at"
        static let trafficAt = "demar_sub_alert_traffic_at"
    }

    static func canShowExpiry(now: Date = .now) -> Bool {
        canShow(key: Key.expiryAt, cooldown: expiryCooldown, now: now)
    }

    static func markExpiryShown(now: Date = .now) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Key.expiryAt)
    }

    static func canShowTraffic(now: Date = .now) -> Bool {
        canShow(key: Key.trafficAt, cooldown: trafficCooldown, now: now)
    }

    static func markTrafficShown(now: Date = .now) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Key.trafficAt)
    }

    static func millisUntilExpiry(_ expiresAtIso: String, now: Date = .now) -> Int64? {
        guard let date = parseISO(expiresAtIso) else { return nil }
        return Int64(date.timeIntervalSince(now) * 1000)
    }

    static func shouldShowExpiry(_ expiresAtIso: String, now: Date = .now) -> Bool {
        guard let ms = millisUntilExpiry(expiresAtIso, now: now), ms > 0 else { return false }
        // (24h, 72h] early · (18h, 24h] silent · (0, 18h] final
        return (ms > expiryEarlyMinMs && ms <= expiryEarlyMaxMs)
            || (ms >= 1 && ms <= expiryFinalMaxMs)
    }

    static func shouldShowTraffic(usedBytes: Int64) -> Bool {
        usedBytes >= trafficThresholdBytes
    }

    /// Hours if ≥1h, otherwise minutes (at least 1).
    static func remainingTime(ms: Int64) -> (hours: Bool, amount: Int) {
        let safe = max(ms, 1)
        if safe >= 3_600_000 {
            return (true, max(Int(safe / 3_600_000), 1))
        }
        return (false, max(Int(safe / 60_000), 1))
    }

    static func formatRemaining(_ ms: Int64) -> String {
        let rem = remainingTime(ms: ms)
        let amount = rem.amount
        if rem.hours {
            return String(format: hoursFormat(amount), amount)
        }
        return String(format: minutesFormat(amount), amount)
    }

    private static func canShow(key: String, cooldown: TimeInterval, now: Date) -> Bool {
        let last = UserDefaults.standard.double(forKey: key)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= cooldown
    }

    private static func parseISO(_ raw: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFrac.date(from: raw) ?? plain.date(from: raw)
    }

    private static func hoursFormat(_ n: Int) -> String {
        pluralFormat(n, one: "in %d hour", few: "in %d hours_few", many: "in %d hours")
    }

    private static func minutesFormat(_ n: Int) -> String {
        pluralFormat(n, one: "in %d minute", few: "in %d minutes_few", many: "in %d minutes")
    }

    private static func pluralFormat(_ n: Int, one: String.LocalizationValue, few: String.LocalizationValue, many: String.LocalizationValue) -> String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        if lang == "ru" || lang == "uk" {
            let m10 = n % 10
            let m100 = n % 100
            if m10 == 1, m100 != 11 { return String(localized: one) }
            if (2...4).contains(m10), !(12...14).contains(m100) { return String(localized: few) }
            return String(localized: many)
        }
        return String(localized: n == 1 ? one : many)
    }
}
