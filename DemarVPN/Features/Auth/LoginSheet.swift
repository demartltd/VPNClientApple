import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum LoginStep: Hashable {
    case email, verify, totp
}

private enum LoginFieldStyle {
    static let fieldInset: CGFloat = 16
    static let controlHeight: CGFloat = 48
}

struct LoginSheet: View {
    var onSignedIn: () -> Void
    var onDismiss: () -> Void

    @State private var step: LoginStep = .email
    @State private var email = ""
    @State private var registering = false
    @State private var showRegisterDialog = false
    @State private var error: String?
    @State private var challengeToken: String?
    @State private var otp = ""
    @State private var busy = false
    @State private var webAuth: WebAuthSession?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.demarTitleMediumBold)
                .foregroundStyle(Color.demarOnSurface)
                .frame(maxWidth: .infinity)
            if step == .verify {
                Text(email)
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            }

            switch step {
            case .email: emailStep
            case .verify, .totp: otpStep
            }

            moreMethods
        }
        .disabled(busy)
        .alert(String(localized: "Account not found"), isPresented: $showRegisterDialog) {
            Button(String(localized: "Create account")) {
                registering = true
                Task { await sendOtp(purpose: "register") }
            }
            Button(String(localized: "Fix email"), role: .cancel) {
                registering = false
            }
        } message: {
            Text("Create a new account for \(email.trimmingCharacters(in: .whitespacesAndNewlines))?")
        }
        .demarSheetChrome(horizontalPadding: 16, bottomPadding: 8)
    }

    private var title: String {
        switch step {
        case .email: String(localized: "Sign in / Register")
        case .verify: String(localized: "Sent to")
        case .totp: String(localized: "Authenticator code")
        }
    }

    private var emailStep: some View {
        VStack(spacing: 12) {
            loginTextField(
                placeholder: "Email",
                text: $email,
                font: .demarBodyMedium,
                centered: false
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            #endif
            .autocorrectionDisabled()
            .onChange(of: email) { _, _ in
                error = nil
                registering = false
            }

            if let error {
                Text(error)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarError)
                    .frame(maxWidth: .infinity)
            }

            Button {
                Task { await sendOtp() }
            } label: {
                Text("Continue")
                    .font(.demarTitleMediumBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.demarPrimary)
            .disabled(busy)
        }
    }

    private var otpStep: some View {
        VStack(spacing: 12) {
            loginTextField(
                placeholder: "",
                text: $otp,
                font: .demarHeadlineMedium,
                centered: true
            )
            #if os(iOS)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            #endif
            .onChange(of: otp) { _, value in
                error = nil
                let digits = value.filter(\.isNumber)
                if digits != value { otp = digits }
                if digits.count == 6 { Task { await submitOtp(digits) } }
            }

            if let error {
                Text(error)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarError)
                    .frame(maxWidth: .infinity)
            }
            if step == .verify {
                Button("Resend code") {
                    Task { await sendOtp() }
                }
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarPrimary)
                .disabled(busy)
            }
        }
    }

    @ViewBuilder
    private func loginTextField(
        placeholder: String,
        text: Binding<String>,
        font: Font,
        centered: Bool
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(font)
            .multilineTextAlignment(centered ? .center : .leading)
            #if os(macOS)
            .padding(.horizontal, LoginFieldStyle.fieldInset)
            .frame(height: LoginFieldStyle.controlHeight)
            #else
            .padding(16)
            #endif
            .background(Color.demarSurfaceContainerHighest, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var moreMethods: some View {
        VStack(spacing: 12) {
            HStack {
                Rectangle().fill(Color.demarOutline.opacity(0.35)).frame(height: 1)
                Text("More Login Methods")
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .fixedSize()
                Rectangle().fill(Color.demarOutline.opacity(0.35)).frame(height: 1)
            }
            .padding(.top, 4)

            Button {
                startTelegram()
            } label: {
                BrandIconView(glyph: "\u{f2c6}", size: 28)
                    .frame(width: 48, height: 48)
                    .background(Color.demarSurfaceContainerHighest, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    private func sendOtp(purpose: String? = nil) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains(".") else {
            error = String(localized: "Invalid email")
            return
        }
        if trimmed == LocalDemoAccount.email {
            AuthSessionStore.signInLocalDemo()
            onSignedIn()
            return
        }
        await runAuth {
            let p = purpose ?? (registering ? "register" : "login")
            do {
                try await AuthSessionStore.sendEmail(trimmed, purpose: p)
                showRegisterDialog = false
                step = .verify
                otp = ""
            } catch let e as DemarAPIError where p == "login" && e.statusCode == 404 && e.hint == "register" {
                showRegisterDialog = true
            }
        }
    }

    private func submitOtp(_ code: String) async {
        await runAuth {
            switch step {
            case .verify:
                switch try await AuthSessionStore.confirmEmail(email, code: code) {
                case .needsTotp(let token):
                    challengeToken = token
                    step = .totp
                    otp = ""
                case .ready:
                    onSignedIn()
                }
            case .totp:
                guard let token = challengeToken else {
                    throw DemarAPIError(message: String(localized: "Invalid code"), statusCode: 0, retryAfterSeconds: nil, hint: nil)
                }
                try await AuthSessionStore.verifyTotp(challengeToken: token, code: code)
                onSignedIn()
            case .email:
                break
            }
        }
    }

    private func startTelegram() {
        let session = WebAuthSession(url: AuthApi.telegramOAuthStartURL) { result in
            Task { @MainActor in
                webAuth = nil
                switch result {
                case .success(let url):
                    await handleCallback(url)
                case .failure(let err):
                    if (err as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        error = String(localized: "Couldn’t sign in. Try again")
                    }
                }
            }
        }
        webAuth = session
        session.start()
    }

    private func handleCallback(_ url: URL) async {
        await runAuth {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let token = items.first(where: { $0.name == "token" })?.value?.nilIfBlank {
                try await AuthSessionStore.completeClientToken(token)
            } else if let code = items.first(where: { $0.name == "code" })?.value?.nilIfBlank {
                try await AuthSessionStore.completeExchange(code)
            } else {
                throw DemarAPIError(message: String(localized: "Couldn’t sign in. Try again"), statusCode: 0, retryAfterSeconds: nil, hint: nil)
            }
            onSignedIn()
        }
    }

    private func runAuth(_ block: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await block()
        } catch let e as DemarAPIError {
            error = e.message.nilIfBlank ?? String(localized: "Couldn’t sign in. Try again")
            otp = ""
        } catch {
            self.error = String(localized: "Couldn’t sign in. Try again")
            otp = ""
        }
    }
}

extension View {
    /// iOS: system sheet. macOS: overlay — tap outside dismisses (system sheet is modal).
    func loginSheet(isPresented: Binding<Bool>, onSignedIn: @escaping () -> Void) -> some View {
        demarBottomSheet(isPresented: isPresented) {
            LoginSheet(
                onSignedIn: {
                    onSignedIn()
                    isPresented.wrappedValue = false
                },
                onDismiss: { isPresented.wrappedValue = false }
            )
        }
    }
}

/// Keeps ASWebAuthenticationSession alive for the duration of the flow.
private final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    init(url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        super.init()
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: DemarURLScheme.name) { callbackURL, error in
            if let callbackURL {
                completion(.success(callbackURL))
            } else {
                completion(.failure(error ?? URLError(.cancelled)))
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
    }

    func start() { session?.start() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        ASPresentationAnchor()
        #endif
    }
}
