import Foundation

enum EmailConfirmResult: Sendable {
    case needsTotp(challengeToken: String)
    case ready(exchangeCode: String)
}

struct SessionExchange: Sendable {
    let userId: String
    let loginAt: String
    let username: String?
}

enum AuthApi {
    static let baseURL = URL(string: "https://auth.example.invalid")!
    static let vpnAPIBaseURL = URL(string: "https://vpn.example.invalid")!
    static let accountBaseURL = URL(string: "https://account.example.invalid")!
    static let appOAuthReturn = accountBaseURL.appendingPathComponent("auth/app/complete")

    static var telegramOAuthStartURL: URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("auth/oauth/telegram/start"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "return_to", value: appOAuthReturn.absoluteString),
            URLQueryItem(name: "client", value: DemarHttp.clientID),
            URLQueryItem(name: "ua", value: DemarHttp.userAgent),
        ]
        return c.url!
    }

    static func sendEmail(email: String, purpose: String = "login") async throws {
        _ = try await DemarHttp.postJSON(
            baseURL.appendingPathComponent("auth/mobile/email/send"),
            body: ["email": email, "purpose": purpose]
        )
    }

    static func confirmEmail(email: String, code: String) async throws -> EmailConfirmResult {
        let json = try await DemarHttp.postJSON(
            baseURL.appendingPathComponent("auth/mobile/email/confirm"),
            body: ["email": email, "code": code]
        )
        if json["requiresTotp"] as? Bool == true {
            guard let token = (json["challengeToken"] as? String)?.nilIfBlank else {
                throw DemarAPIError(message: "Missing challengeToken", statusCode: 0, retryAfterSeconds: nil, hint: nil)
            }
            return .needsTotp(challengeToken: token)
        }
        guard let exchange = (json["exchangeCode"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing exchangeCode", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        return .ready(exchangeCode: exchange)
    }

    static func verifyTotp(challengeToken: String, code: String) async throws -> String {
        let json = try await DemarHttp.postJSON(
            baseURL.appendingPathComponent("auth/mobile/totp/verify"),
            body: ["challengeToken": challengeToken, "code": code]
        )
        guard let exchange = (json["exchangeCode"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing exchangeCode", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        return exchange
    }

    static func exchangeSession(code: String) async throws -> SessionExchange {
        let json = try await DemarHttp.postJSON(
            baseURL.appendingPathComponent("auth/mobile/session/exchange"),
            body: ["code": code]
        )
        return try parseSession(json)
    }

    static func checkSession(userId: String, loginAt: String) async throws -> SessionExchange {
        let json = try await DemarHttp.postJSON(
            baseURL.appendingPathComponent("auth/mobile/session/check"),
            body: ["userId": userId, "loginAt": loginAt]
        )
        return try parseSession(json)
    }

    static func logoutSession(userId: String, loginAt: String) async throws {
        _ = try await DemarHttp.postJSON(
            baseURL.appendingPathComponent("auth/mobile/session/logout"),
            body: ["userId": userId, "loginAt": loginAt]
        )
    }

    static func sessionFromClientToken(_ token: String) async throws -> SessionExchange {
        let json = try await DemarHttp.getJSON(
            accountBaseURL.appendingPathComponent("api/auth/client/me"),
            bearer: token
        )
        guard let loginAt = (json["loginAt"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing loginAt", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        guard let profile = json["profile"] as? [String: Any] else {
            throw DemarAPIError(message: "Missing profile", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        guard let userId = (profile["id"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing userId", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        return SessionExchange(
            userId: userId,
            loginAt: loginAt,
            username: (profile["username"] as? String)?.nilIfBlank
        )
    }

    private static func parseSession(_ json: [String: Any]) throws -> SessionExchange {
        guard let userId = (json["userId"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing userId", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        guard let loginAt = (json["loginAt"] as? String)?.nilIfBlank else {
            throw DemarAPIError(message: "Missing loginAt", statusCode: 0, retryAfterSeconds: nil, hint: nil)
        }
        return SessionExchange(
            userId: userId,
            loginAt: loginAt,
            username: (json["username"] as? String)?.nilIfBlank
        )
    }
}
