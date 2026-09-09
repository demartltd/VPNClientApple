import Foundation
import os

struct PayPeriodPrices: Sendable, Equatable {
    let rub: String
    let eur: String

    func amount(currency: String) -> String {
        currency.uppercased() == "EUR" ? eur : rub
    }
}

struct PayPeriodOption: Sendable, Equatable, Identifiable {
    let period: String
    let days: Int
    let prices: PayPeriodPrices
    var id: String { period }
}

struct PayTierOption: Sendable, Equatable, Identifiable {
    let tier: String
    let periods: [PayPeriodOption]
    var id: String { tier }
}

struct PayCatalog: Sendable, Equatable {
    let tiers: [PayTierOption]

    func price(tier: String, period: String, currency: String) -> String? {
        tiers.first(where: { $0.tier == tier })?
            .periods.first(where: { $0.period == period })?
            .prices.amount(currency: currency)
    }
}

struct PayCheckout: Sendable {
    let orderId: String
    let payUrl: URL
    let amount: String
    let currency: String
    let discountPercent: Int?
}

enum PayApi {
    private static let plans = OSAllocatedUnfairLock<PayCatalog?>(initialState: nil)

    /// Last successful catalog (nil until first fetch).
    static var cachedPlans: PayCatalog? {
        plans.withLock { $0 }
    }

    /// Visible for tests.
    static func clearCachedPlans() {
        plans.withLock { $0 = nil }
    }

    /// Visible for tests.
    static func seedCachedPlans(_ catalog: PayCatalog) {
        plans.withLock { $0 = catalog }
    }

    static func warmPlans() async {
        do { _ = try await fetchPlans() } catch { /* preload best-effort */ }
    }

    static func fetchPlans() async throws -> PayCatalog {
        if let hit = cachedPlans { return hit }
        return try await KeyedFlight.run("pay.plans") {
            if let hit = cachedPlans { return hit }
            let catalog = parseCatalog(try await DemarHttp.vpnGet("vpn/pay/plans"))
            if !catalog.tiers.isEmpty {
                plans.withLock { $0 = catalog }
            }
            return catalog
        }
    }

    static func create(
        userId: String,
        loginAt: String,
        tier: String,
        period: String,
        currency: String,
        code: String? = nil
    ) async throws -> PayCheckout {
        var body: [String: Any] = [
            "userId": userId,
            "loginAt": loginAt,
            "tier": tier,
            "period": period,
            "currency": currency.uppercased(),
        ]
        if let code, !code.isEmpty { body["code"] = code }
        guard let checkout = parseCheckout(try await DemarHttp.vpnPost("vpn/pay/create", body)) else {
            throw DemarAPIError(message: "invalid_checkout", statusCode: 502, retryAfterSeconds: nil, hint: nil)
        }
        return checkout
    }

    static func parseCatalog(_ json: [String: Any]) -> PayCatalog {
        let rows = json["plans"] as? [[String: Any]] ?? []
        let tiers = rows.compactMap { row -> PayTierOption? in
            guard let tier = (row["tier"] as? String)?.nilIfBlank else { return nil }
            let periods = (row["periods"] as? [[String: Any]] ?? []).compactMap { p -> PayPeriodOption? in
                guard let period = (p["period"] as? String)?.nilIfBlank else { return nil }
                let prices = p["prices"] as? [String: Any] ?? [:]
                return PayPeriodOption(
                    period: period,
                    days: p["days"] as? Int ?? 0,
                    prices: PayPeriodPrices(
                        rub: stringPrice(prices["RUB"]),
                        eur: stringPrice(prices["EUR"])
                    )
                )
            }
            return PayTierOption(tier: tier, periods: periods)
        }
        return PayCatalog(tiers: tiers)
    }

    static func parseCheckout(_ json: [String: Any]) -> PayCheckout? {
        guard
            let orderId = (json["orderId"] as? String)?.nilIfBlank,
            let payUrlRaw = (json["payUrl"] as? String)?.nilIfBlank,
            let payUrl = URL(string: payUrlRaw)
        else { return nil }
        return PayCheckout(
            orderId: orderId,
            payUrl: payUrl,
            amount: stringPrice(json["amount"]),
            currency: ((json["currency"] as? String) ?? "RUB").uppercased(),
            discountPercent: json["discountPercent"] as? Int
        )
    }

    /// RUB whole rubles; EUR tenths (site parity).
    static func formatPrice(_ amount: String, currency: String) -> String {
        let n = Double(amount) ?? 0
        if currency.uppercased() == "EUR" {
            let v = (n * 10).rounded() / 10
            return abs(v - v.rounded()) < 0.000_1 ? "€\(Int(v))" : String(format: "€%.1f", v)
        }
        return "\(Int(n.rounded())) ₽"
    }

    static func discountedDisplay(major: String, percent: Int, currency: String) -> String {
        let n = Double(major) ?? 0
        let p = min(100, max(0, percent))
        let raw = n * Double(100 - p) / 100
        let amount: String
        if currency.uppercased() == "EUR" {
            let v = max(1.0, (raw * 10).rounded() / 10)
            amount = String(format: "%.2f", v)
        } else {
            amount = String(Int(max(30, raw.rounded())))
        }
        return formatPrice(amount, currency: currency)
    }

    private static func stringPrice(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return String(format: "%.2f", n.doubleValue) }
        return "0.00"
    }
}
