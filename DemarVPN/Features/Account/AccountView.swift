import SwiftUI

struct AccountView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    var onNeedSignIn: (() -> Void)?

    @State private var signingOut = false
    @State private var notifyBusy = false
    @State private var showTraffic = false
    @State private var showNotify = false
    @State private var showSignOutConfirm = false

    private let familySlots = 4
    private let familyOccupied = 3

    private var account: VpnAccount? { appState.account }
    private var traffic: VpnTraffic? { appState.traffic }
    private var loading: Bool { appState.accountLoading }

    var body: some View {
        Group {
            if isActive {
                ScrollView {
                    VStack(spacing: 32) {
                        header
                        if let session = appState.authSession {
                            signedIn(session)
                        } else {
                            guestCTA
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                    .padding(.bottom, 20)
                }
                .demarScrollScreen()
            } else {
                Color.clear
            }
        }
        .background(Color.demarSurface)
        .demarBottomSheet(isPresented: $showNotify) { notifySheet }
        .demarBottomSheet(isPresented: $showTraffic) { trafficSheet }
        .alert(
            String(localized: "Sign out?"),
            isPresented: $showSignOutConfirm
        ) {
            Button(String(localized: "Sign out"), role: .destructive) { performSignOut() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "End the session on this device."))
        }
        .tint(showSignOutConfirm ? Color.demarOnSurface : Color.demarPrimary)
        #if os(iOS)
        .demarNavigationRoot(backHistoryLabel: String(localized: "Account"))
        #endif
    }

    private var soon: () -> Void {
        { snackBar.showInfo(String(localized: "Coming soon")) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.demarPrimary)
                .padding(.bottom, 8)
            Text(appState.authSession?.username ?? String(localized: "Account"))
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
                .multilineTextAlignment(.center)
            if let session = appState.authSession {
                Text(String(localized: "ID: \(session.userId)"))
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        PlatformServices.copyToPasteboard(session.userId)
                        snackBar.showInfo(String(localized: "ID copied"))
                    }
            } else {
                Text(String(localized: "Sign in to sync your subscription and servers"))
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Signed in

    private func signedIn(_ session: AuthSession) -> some View {
        let rawPlan = (account?.vpnSubscription ?? session.vpnSubscription)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isFree = (rawPlan ?? "").caseInsensitiveCompare("free") == .orderedSame
        let planLabel = rawPlan.flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() }
            ?? String(localized: "—")
        let expires = isFree ? nil : formatExpiry(account?.vpnExpiresAt ?? session.vpnExpiresAt)
        let progress = trafficProgress
        let trafficFull = (progress ?? 0) >= 1

        return VStack(spacing: 12) {
            subscriptionCard(plan: planLabel, expires: expires, isFree: isFree)

            SettingsActionButton(
                systemImage: "chart.bar.fill",
                title: String(localized: "Traffic this month"),
                subtitle: trafficSubtitle,
                danger: trafficFull,
                showsChevron: true,
                action: { showTraffic = true },
                extra: {
                    if let progress {
                        ProgressView(value: Double(progress))
                            .tint(trafficFull ? Color.demarError : Color.demarPrimary)
                            .padding(.top, 4)
                    }
                }
            )

            familyCard

            SettingsActionButton(
                systemImage: "bell.fill",
                title: String(localized: "Notifications"),
                subtitle: String(localized: "Notification settings"),
                showsChevron: true,
                action: { showNotify = true }
            )

            SettingsActionButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: signingOut ? String(localized: "Loading…") : String(localized: "Sign out"),
                subtitle: String(localized: "End session on this device"),
                showsChevron: true,
                action: {
                    guard !signingOut else { return }
                    showSignOutConfirm = true
                }
            )
            .disabled(signingOut)
            .opacity(signingOut ? 0.55 : 1)
        }
    }

    private var trafficProgress: Float? {
        guard let t = traffic else { return nil }
        guard t.limitBytes > 0 else { return 0 }
        return min(1, max(0, Float(t.total) / Float(t.limitBytes)))
    }

    private var trafficSubtitle: String {
        if traffic == nil && loading { return String(localized: "Loading…") }
        guard let t = traffic, let p = trafficProgress else {
            return String(localized: "Traffic unavailable")
        }
        let pct = Int((p * 100).rounded(.down))
        return String(
            format: String(localized: "%@ / %@ · %d%%"),
            VpnAccountApi.formatBytes(t.total),
            VpnAccountApi.formatBytes(t.limitBytes),
            pct
        )
    }

    // MARK: - Cards

    private func subscriptionCard(plan: String, expires: String?, isFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading && account == nil {
                ProgressView()
                    .tint(Color.demarPrimary)
                    .padding(8)
            } else {
                metaRow(systemImage: "crown.fill", label: String(localized: "Plan"), value: plan)
                if let expires {
                    metaRow(systemImage: "calendar", label: String(localized: "Expires"), value: expires)
                        .padding(.top, 12)
                }
                Button(action: soon) {
                    Text(String(localized: isFree ? "Buy subscription" : "Renew subscription"))
                        .font(.demarTitleMedium)
                        .foregroundStyle(Color.demarOnPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.demarPrimary)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
        )
    }

    private func metaRow(systemImage: String, label: String, value: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(Color.demarPrimary)
                .frame(width: 24, height: 24)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.demarPrimary.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.demarTitleMedium)
                    .foregroundStyle(Color.demarOnSurface)
                Text(value)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
    }

    private var familyCard: some View {
        Button(action: soon) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Add loved ones to family"))
                    .font(.demarTitleMedium)
                    .foregroundStyle(Color.demarOnSurface)
                Text(String(localized: "Your subscription can be used by four people"))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "1 free spot"))
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                        HStack(spacing: 8) {
                            ForEach(0..<familyOccupied, id: \.self) { _ in
                                familyAvatar(occupied: true)
                            }
                            ForEach(0..<(familySlots - familyOccupied), id: \.self) { _ in
                                familyAvatar(occupied: false)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text(String(localized: "Change"))
                        .font(.demarLabelLarge)
                        .foregroundStyle(Color.demarPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.demarPrimary.opacity(0.15))
                        )
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.demarSurfaceContainerHighest)
                )
                .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func familyAvatar(occupied: Bool) -> some View {
        Group {
            if occupied {
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.demarOnSurfaceVariant.opacity(0.55))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.demarOutline.opacity(0.28)))
            } else {
                Circle()
                    .strokeBorder(
                        Color.demarOutline.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .frame(width: 36, height: 36)
            }
        }
    }

    // MARK: - Sheets

    private var notifySheet: some View {
        Group {
            if let a = account {
                VStack(spacing: 8) {
                    notifyRow(String(localized: "News and offers"), a.notifyNews) { setNotify(news: $0) }
                    notifyRow(String(localized: "Important notices"), a.notifyImportant) { setNotify(important: $0) }
                }
            } else if loading {
                Text(String(localized: "Loading…"))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            }
        }
        .demarSheetChrome(bottomPadding: 8)
    }

    private var trafficSheet: some View {
        Group {
            if let t = traffic {
                TrafficPieChart(
                    servers: t.servers,
                    otherLabel: String(localized: "Other"),
                    centerPrimary: VpnAccountApi.formatBytes(t.total)
                )
            } else if loading {
                Text(String(localized: "Loading…"))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            } else {
                Text(String(localized: "Traffic unavailable"))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            }
        }
        .demarSheetChrome(bottomPadding: 8)
    }

    private func notifyRow(_ label: String, _ checked: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(label)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurface)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { checked }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.demarPrimary)
                .accessibilityLabel(label)
        }
        .disabled(notifyBusy)
        .padding(.vertical, 4)
    }

    private var guestCTA: some View {
        SettingsActionButton(
            systemImage: "arrow.right.circle.fill",
            title: String(localized: "Sign in"),
            subtitle: String(localized: "Sync subscription and servers"),
            action: { onNeedSignIn?() }
        )
    }

    // MARK: - Actions

    private func performSignOut() {
        guard !signingOut else { return }
        signingOut = true
        Task {
            defer { signingOut = false }
            do {
                try await appState.signOut()
                snackBar.showInfo(String(localized: "You signed out"))
            } catch {
                snackBar.showError(String(localized: "Couldn’t sign out. Try again"))
            }
        }
    }

    private func setNotify(news: Bool? = nil, important: Bool? = nil) {
        guard let cur = account, let session = appState.authSession, !notifyBusy else { return }
        let next = VpnAccount(
            notifyNews: news ?? cur.notifyNews,
            notifyImportant: important ?? cur.notifyImportant,
            vpnSubscription: cur.vpnSubscription,
            vpnExpiresAt: cur.vpnExpiresAt
        )
        if session.isLocalDemo {
            appState.account = next
            return
        }
        appState.account = next
        notifyBusy = true
        Task {
            defer { notifyBusy = false }
            do {
                let updated = try await VpnAccountApi.updateNotify(
                    userId: session.userId,
                    loginAt: session.loginAt,
                    notifyNews: news,
                    notifyImportant: important
                )
                if var a = appState.account {
                    a.notifyNews = updated.notifyNews
                    a.notifyImportant = updated.notifyImportant
                    appState.account = a
                }
            } catch let e as DemarAPIError where e.isSessionInvalid {
                appState.account = cur
                await appState.forceLocalSignOut()
            } catch {
                appState.account = cur
                snackBar.showError(String(localized: "Couldn’t update notifications"))
            }
        }
    }

    private func formatExpiry(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFrac.date(from: raw) ?? plain.date(from: raw) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = cal.startOfDay(for: Date())
        let day = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: day).day ?? 0

        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .long
        f.timeStyle = .none
        f.timeZone = TimeZone(secondsFromGMT: 0)
        let formatted = f.string(from: date)
        let relative: String
        if days > 0 {
            relative = String(format: Self.daysFormat(days), days)
        } else {
            relative = String(localized: "today")
        }
        return String(format: String(localized: "%@ (%@)"), formatted, relative)
    }

    private static func daysFormat(_ days: Int) -> String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        if lang == "ru" {
            let m10 = days % 10
            let m100 = days % 100
            if m10 == 1, m100 != 11 {
                return String(localized: "in %d day")
            }
            if (2...4).contains(m10), !(12...14).contains(m100) {
                return String(localized: "in %d days_few")
            }
            return String(localized: "in %d days")
        }
        return String(localized: days == 1 ? "in %d day" : "in %d days")
    }
}

private extension Result where Failure == Error {
    var failure: Error? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
