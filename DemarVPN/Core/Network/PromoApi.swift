import Foundation

struct PromoResult: Sendable {
    let result: String
    let message: String
    let subscription: String?
    let expiresAt: String?
    let discountPercent: Int?

    var isActivated: Bool { result == "activated" }
    var isApplied: Bool { result == "applied" }

    var localizedMessage: String {
        switch result {
        case "activated":   return String(localized: "Promo code activated! Subscription has been applied.")
        case "applied":     return String(localized: "Promo code applied.")
        case "not_found":   return String(localized: "Promo code not found.")
        case "already_used": return String(localized: "This promo code has already been used.")
        case "blocked_by_other": return String(localized: "You cannot activate this promo code.")
        case "expired":     return String(localized: "This promo code has expired.")
        default:            return message
        }
    }
}

enum PromoApi {
    static func activate(code: String, userId: String, loginAt: String) async throws -> PromoResult {
        parse(try await DemarHttp.vpnPost("vpn/promo/activate", [
            "userId": userId, "loginAt": loginAt, "code": code,
        ]))
    }

    /// Discount preview for checkout (does not consume the code).
    static func apply(code: String, userId: String, loginAt: String) async throws -> PromoResult {
        parse(try await DemarHttp.vpnPost("vpn/promo/apply", [
            "userId": userId, "loginAt": loginAt, "code": code,
        ]))
    }

    private static func parse(_ json: [String: Any]) -> PromoResult {
        PromoResult(
            result: (json["result"] as? String) ?? "not_found",
            message: (json["message"] as? String) ?? "",
            subscription: (json["subscription"] as? String)?.nilIfBlank,
            expiresAt: (json["expiresAt"] as? String)?.nilIfBlank,
            discountPercent: json["discountPercent"] as? Int
        )
    }
}
