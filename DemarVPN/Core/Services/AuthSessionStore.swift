import Foundation

struct AuthSession: Equatable, Sendable {
    let userId: String
    let loginAt: String
    let username: String
    let vpnSubscription: String?
    let vpnExpiresAt: String?
    let isLocalDemo: Bool
}

enum LocalDemoAccount {
    static let email = "test@test.com"
    static let userId = "demo"
    static let loginAt = "2020-01-01T00:00:00.000Z"
    static let username = "App Store Review"
    static let vpnSubscription = "FREE"
    static let vpnExpiresAt = "2099-12-31T23:59:59.000Z"
}

@MainActor
enum AuthSessionStore {
    private enum Key {
        static let userId = "demar_auth_user_id"
        static let loginAt = "demar_auth_login_at"
        static let username = "demar_auth_username"
        static let vpnSub = "demar_auth_vpn_subscription"
        static let vpnExpires = "demar_auth_vpn_expires_at"
        static let isLocalDemo = "demar_auth_is_local_demo"
    }

    private(set) static var session: AuthSession? = load()

    static var isSignedIn: Bool { session != nil }

    static func save(_ exchange: SessionExchange, isLocalDemo: Bool = false) {
        let s = AuthSession(
            userId: exchange.userId,
            loginAt: exchange.loginAt,
            username: exchange.username?.nilIfBlank ?? exchange.userId,
            vpnSubscription: exchange.vpnSubscription,
            vpnExpiresAt: exchange.vpnExpiresAt,
            isLocalDemo: isLocalDemo
        )
        persist(s)
    }

    static func signInLocalDemo() {
        let s = AuthSession(
            userId: LocalDemoAccount.userId,
            loginAt: LocalDemoAccount.loginAt,
            username: LocalDemoAccount.username,
            vpnSubscription: LocalDemoAccount.vpnSubscription,
            vpnExpiresAt: LocalDemoAccount.vpnExpiresAt,
            isLocalDemo: true
        )
        persist(s)
        AppLog.shared.append("[auth] signed in as local demo")
    }

    static func clearLocal() {
        let d = UserDefaults.standard
        [Key.userId, Key.loginAt, Key.username, Key.vpnSub, Key.vpnExpires, Key.isLocalDemo]
            .forEach { d.removeObject(forKey: $0) }
        session = nil
        AppLog.shared.append("[auth] signed out")
    }

    /// Returns false when session revoked; network errors keep local session.
    @discardableResult
    static func refreshSession() async -> Bool {
        guard let current = session else { return false }
        if current.isLocalDemo { return true }
        do {
            save(try await AuthApi.checkSession(userId: current.userId, loginAt: current.loginAt))
            return true
        } catch let e as DemarAPIError where e.statusCode == 401 || e.message == "session_revoked" {
            clearLocal()
            AppLog.shared.append("[auth] session inactive — signed out")
            return false
        } catch {
            AppLog.shared.append("[auth] session check failed — \(error.localizedDescription)")
            return true
        }
    }

    static func sendEmail(_ email: String, purpose: String = "login") async throws {
        try await AuthApi.sendEmail(email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), purpose: purpose)
        AppLog.shared.append("[auth] email OTP sent (\(purpose))")
    }

    static func confirmEmail(_ email: String, code: String) async throws -> EmailConfirmResult {
        let result = try await AuthApi.confirmEmail(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if case .ready(let exchange) = result {
            try await completeExchange(exchange)
        }
        return result
    }

    static func verifyTotp(challengeToken: String, code: String) async throws {
        let exchange = try await AuthApi.verifyTotp(
            challengeToken: challengeToken,
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try await completeExchange(exchange)
    }

    static func completeExchange(_ code: String) async throws {
        let exchange = try await AuthApi.exchangeSession(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        save(exchange)
        AppLog.shared.append("[auth] signed in as \(exchange.userId)")
    }

    static func completeClientToken(_ token: String) async throws {
        let exchange = try await AuthApi.sessionFromClientToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
        save(exchange)
        AppLog.shared.append("[auth] signed in as \(exchange.userId) (oauth token)")
    }

    /// Clears local session only after successful logout (2xx) or 404 (already gone / user missing).
    /// Network / other errors keep the session and rethrow. Local demo skips the API.
    static func signOut() async throws {
        guard let current = session else {
            clearLocal()
            return
        }
        if current.isLocalDemo {
            clearLocal()
            return
        }
        do {
            try await AuthApi.logoutSession(userId: current.userId, loginAt: current.loginAt)
            clearLocal()
        } catch let e as DemarAPIError where e.statusCode == 404 {
            clearLocal()
            AppLog.shared.append("[auth] logout: session/user gone — cleared local")
        } catch {
            AppLog.shared.append("[auth] logout failed — \(error.localizedDescription)")
            throw error
        }
    }

    private static func persist(_ s: AuthSession) {
        let d = UserDefaults.standard
        d.set(s.userId, forKey: Key.userId)
        d.set(s.loginAt, forKey: Key.loginAt)
        d.set(s.username, forKey: Key.username)
        d.set(s.vpnSubscription, forKey: Key.vpnSub)
        d.set(s.vpnExpiresAt, forKey: Key.vpnExpires)
        d.set(s.isLocalDemo, forKey: Key.isLocalDemo)
        session = s
    }

    private static func load() -> AuthSession? {
        let d = UserDefaults.standard
        guard let userId = d.string(forKey: Key.userId)?.nilIfBlank,
              let loginAt = d.string(forKey: Key.loginAt)?.nilIfBlank
        else { return nil }
        return AuthSession(
            userId: userId,
            loginAt: loginAt,
            username: d.string(forKey: Key.username)?.nilIfBlank ?? userId,
            vpnSubscription: d.string(forKey: Key.vpnSub)?.nilIfBlank,
            vpnExpiresAt: d.string(forKey: Key.vpnExpires)?.nilIfBlank,
            isLocalDemo: d.bool(forKey: Key.isLocalDemo)
        )
    }
}
