import Foundation

struct PromoResult: Sendable {
    let result: String
    let message: String
    let subscription: String?
    let expiresAt: String?

    var isActivated: Bool { result == "activated" }

    var localizedMessage: String {
        switch result {
        case "activated":   return String(localized: "Promo code activated! Subscription has been applied.")
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
        let body: [String: Any] = ["userId": userId, "loginAt": loginAt, "code": code]
        let json = try await DemarHttp.postJSON(
            AuthApi.vpnAPIBaseURL.appendingPathComponent("vpn/promo/activate"),
            body: body
        )
        return PromoResult(
            result: (json["result"] as? String) ?? "not_found",
            message: (json["message"] as? String) ?? "",
            subscription: (json["subscription"] as? String)?.nilIfBlank,
            expiresAt: (json["expiresAt"] as? String)?.nilIfBlank
        )
    }
}
