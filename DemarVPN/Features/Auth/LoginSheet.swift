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

#if os(iOS)
private struct LoginSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif

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
    #if os(iOS)
    @State private var sheetHeight: CGFloat = 340
    #endif

    var body: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            Capsule()
                .fill(Color.demarOnSurface.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 20)
                .padding(.bottom, 8)
            #endif

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
        .padding(.horizontal, 16)
        #if os(macOS)
        .padding(.top, 16)
        #endif
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        #if os(iOS)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: LoginSheetHeightKey.self, value: geo.size.height)
            }
        }
        .onPreferenceChange(LoginSheetHeightKey.self) { height in
            guard height > 0, abs(height - sheetHeight) > 1 else { return }
            sheetHeight = height
        }
        #endif
        .background(Color.demarSurface)
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
        #if os(iOS)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.hidden)
        #endif
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
                Group {
                    if busy { ProgressView() }
                    else { Text("Continue").font(.demarTitleMediumBold) }
                }
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
            if busy { ProgressView() }
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
        VStack(spacing: 16) {
            HStack {
                Rectangle().fill(Color.demarOutline.opacity(0.35)).frame(height: 1)
                Text("More Login Methods")
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .fixedSize()
                Rectangle().fill(Color.demarOutline.opacity(0.35)).frame(height: 1)
            }
            .padding(.top, 8)

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
        #if os(iOS)
        sheet(isPresented: isPresented, onDismiss: {}) {
            LoginSheet(
                onSignedIn: {
                    onSignedIn()
                    isPresented.wrappedValue = false
                },
                onDismiss: { isPresented.wrappedValue = false }
            )
        }
        #else
        modifier(LoginSheetMacOverlay(isPresented: isPresented, onSignedIn: onSignedIn))
        #endif
    }
}

#if os(macOS)
private struct LoginSheetMacOverlay: ViewModifier {
    @Binding var isPresented: Bool
    let onSignedIn: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }

                    LoginSheet(
                        onSignedIn: {
                            onSignedIn()
                            isPresented = false
                        },
                        onDismiss: { isPresented = false }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                    .padding(16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented)
    }
}
#endif

/// Keeps ASWebAuthenticationSession alive for the duration of the flow.
private final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    init(url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        super.init()
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "demar") { callbackURL, error in
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
