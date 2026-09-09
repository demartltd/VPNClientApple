import SwiftUI

enum CheckoutIntent: String, Sendable, Equatable {
    case buy, renew, upgradeTraffic

    func defaultTier(current: String?) -> String {
        let t = (current ?? "free").lowercased()
        switch self {
        case .buy: return "plus"
        case .renew: return ["plus", "vip"].contains(t) ? t : "plus"
        case .upgradeTraffic:
            if t == "vip" || t == "dev" { return "vip" }
            if t == "plus" || t == "tester" { return "vip" }
            return "plus"
        }
    }
}

struct SubscriptionCheckoutSheet: View {
    @Bindable var appState: AppState
    var snackBar: SnackBarController
    let intent: CheckoutIntent
    var onDismiss: () -> Void

    @State private var catalog: PayCatalog? = PayApi.cachedPlans
    @State private var tier = "plus"
    @State private var period = "month"
    @State private var currency = "RUB"
    @State private var paying = false
    @State private var loadingPlans = PayApi.cachedPlans == nil
    @State private var plansError: String?

    @State private var promoCode = ""
    @State private var appliedCode: String?
    @State private var discountPercent = 0
    @State private var showPromoInput = false
    @State private var showPromoResult = false
    @State private var promoResultMessage = ""

    private static let periods = ["week", "month", "quarter", "year"]
    private static let periodBadges: [String: String] = ["quarter": "−20%", "year": "−33%"]

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .demarSheetChrome(bottomPadding: 8)
        .task(id: intent) {
            tier = intent.defaultTier(current: appState.account?.vpnSubscription
                ?? appState.authSession?.vpnSubscription)
            await loadPlans()
        }
        .alert(String(localized: "Enter promo code"), isPresented: $showPromoInput) {
            TextField("DEMAR10", text: $promoCode)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .onChange(of: promoCode) { _, new in
                    let filtered = new.uppercased().filter { $0.isLetter && $0.isASCII || $0.isNumber }
                    if filtered != new { promoCode = filtered }
                }
            Button(String(localized: "Apply")) { Task { await applyPromo() } }
            Button(String(localized: "Cancel"), role: .cancel) { promoCode = "" }
        } message: {
            Text(String(localized: "Discount promo for this purchase"))
        }
        .alert(promoResultMessage, isPresented: $showPromoResult) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
        .tint(Color.white)
    }

    // MARK: - iOS (tier segment + 4 period rows)

    #if os(iOS)
    private var iosBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text(String(localized: "Subscription"))
                    .font(.demarHeadlineMedium)
                    .foregroundStyle(Color.demarOnSurface)
                Spacer(minLength: 8)
                currencyCircles
            }

            CheckoutSegmentBar(
                options: [("plus", "Plus"), ("vip", "VIP")],
                selectedID: tier
            ) { tier = $0 }

            VStack(spacing: 8) {
                ForEach(Self.periods, id: \.self) { p in
                    periodRow(p)
                }
            }

            priceBlock

            promoButton

            if let plansError {
                Text(plansError)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarError)
            }

            HStack(spacing: 12) {
                secondaryButton(String(localized: "Compare plans")) {
                    appState.openPlanCompare()
                }
                primaryButton(
                    title: paying ? String(localized: "Loading…") : String(localized: "Pay"),
                    enabled: !paying && !loadingPlans && catalog != nil
                ) { Task { await pay(tier: tier) } }
            }
        }
    }

    private func periodRow(_ p: String) -> some View {
        let selected = period == p
        return Button {
            period = p
            PlatformServices.lightImpact()
        } label: {
            HStack {
                Text(periodLabel(p))
                    .font(.demarTitleMedium)
                    .foregroundStyle(Color.demarOnSurface)
                if let badge = Self.periodBadges[p] {
                    Text(badge)
                        .font(.demarBodySmall)
                        .foregroundStyle(Color.demarPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.demarPrimary.opacity(0.15)))
                }
                Spacer(minLength: 0)
                if let major = catalog?.price(tier: tier, period: p, currency: currency) {
                    Text(PayApi.formatPrice(major, currency: currency))
                        .font(.demarTitleMedium)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.demarPrimary.opacity(0.14) : Color.demarSurfaceContainerHighest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.demarPrimary.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - macOS (period pills + Plus/VIP cards, site-like)

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                periodPills
                Spacer(minLength: 8)
                currencyCircles
            }

            HStack(alignment: .top, spacing: 12) {
                planCard(
                    tierID: "plus",
                    name: "Plus",
                    tagline: String(localized: "For everyday use"),
                    featured: true,
                    perks: [
                        String(localized: "Premium servers"),
                        String(localized: "100 Mbps"),
                        String(localized: "500 GB traffic"),
                    ]
                )
                planCard(
                    tierID: "vip",
                    name: "VIP",
                    tagline: String(localized: "Maximum features"),
                    featured: false,
                    perks: [
                        String(localized: "Dedicated servers"),
                        String(localized: "300 Mbps"),
                        String(localized: "3000 GB traffic"),
                    ]
                )
            }

            promoButton

            if let plansError {
                Text(plansError)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarError)
            }

            HStack(spacing: 12) {
                secondaryButton(String(localized: "Compare plans")) {
                    appState.openPlanCompare()
                }
                primaryButton(
                    title: paying ? String(localized: "Loading…") : String(localized: "Pay"),
                    enabled: !paying && !loadingPlans && catalog != nil
                ) { Task { await pay(tier: tier) } }
            }
        }
    }

    private var periodPills: some View {
        HStack(spacing: 4) {
            ForEach(Self.periods, id: \.self) { p in
                let on = period == p
                Button {
                    period = p
                    PlatformServices.lightImpact()
                } label: {
                    HStack(spacing: 6) {
                        Text(periodLabel(p))
                            .font(.demarLabelLarge)
                        if let badge = Self.periodBadges[p] {
                            Text(badge)
                                .font(.demarBodySmall)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(on ? Color.white.opacity(0.18) : Color.demarPrimary.opacity(0.15))
                                )
                        }
                    }
                    .foregroundStyle(on ? Color.demarOnPrimary : Color.demarOnSurfaceVariant)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(on ? Color.demarOnSurface : Color.clear)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule().fill(Color.demarSurfaceContainerHighest.opacity(0.85))
        )
    }

    private func planCard(
        tierID: String,
        name: String,
        tagline: String,
        featured: Bool,
        perks: [String]
    ) -> some View {
        let selected = tier == tierID
        return Button {
            tier = tierID
            PlatformServices.lightImpact()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(name)
                        .font(.demarHeadlineMedium)
                        .foregroundStyle(Color.demarOnSurface)
                    if featured {
                        Text(String(localized: "Popular"))
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.demarPrimary.opacity(0.15)))
                    }
                    Spacer(minLength: 8)
                    cardPriceBlock(tier: tierID)
                }

                Text(tagline)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(perks, id: \.self) { perk in
                        Text("• \(perk)")
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurface)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.demarPrimary.opacity(0.14) : Color.demarSurfaceContainerHighest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected
                            ? Color.demarPrimary.opacity(0.45)
                            : Color.demarOutline.opacity(0.2),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cardPriceBlock(tier: String) -> some View {
        let major = catalog?.price(tier: tier, period: period, currency: currency)
        return VStack(alignment: .trailing, spacing: 2) {
            if let major {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if discountPercent > 0 {
                        Text(PayApi.formatPrice(major, currency: currency))
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .strikethrough()
                        Text(PayApi.discountedDisplay(major: major, percent: discountPercent, currency: currency))
                            .font(.demarHeadlineMedium)
                            .foregroundStyle(Color.demarOnSurface)
                    } else {
                        Text(PayApi.formatPrice(major, currency: currency))
                            .font(.demarHeadlineMedium)
                            .foregroundStyle(Color.demarOnSurface)
                    }
                }
                Text(periodPriceSub(period))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            } else if loadingPlans {
                Text(String(localized: "Loading…"))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            } else {
                Text("—")
                    .font(.demarHeadlineMedium)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            }
        }
    }

    private func periodPriceSub(_ p: String) -> String {
        switch p {
        case "week": String(localized: "per week")
        case "month": String(localized: "per month")
        case "quarter": String(localized: "for 3 months")
        case "year": String(localized: "per year")
        default: ""
        }
    }
    #endif

    // MARK: - Shared

    private var currencyCircles: some View {
        HStack(spacing: 4) {
            ForEach([("RUB", "₽"), ("EUR", "€")], id: \.0) { id, label in
                let on = currency == id
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { currency = id }
                    PlatformServices.lightImpact()
                } label: {
                    Text(label)
                        .font(.demarTitleMedium)
                        .foregroundStyle(on ? Color.demarOnPrimary : Color.demarOnSurfaceVariant)
                        .frame(width: 40, height: 40)
                        .background {
                            if on {
                                Circle().fill(Color.demarOnSurface)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(Color.demarSurfaceContainerHighest.opacity(0.85))
        )
    }

    private var promoButton: some View {
        Button {
            showPromoInput = true
        } label: {
            Label(
                appliedCode.map { "\($0) (−\(discountPercent)%)" }
                    ?? String(localized: "Promo code"),
                systemImage: "tag"
            )
            .font(.demarLabelLarge)
            .foregroundStyle(Color.demarPrimary)
        }
        .buttonStyle(.plain)
    }

    #if os(iOS)
    private var priceBlock: some View {
        Group {
            if let major = catalog?.price(tier: tier, period: period, currency: currency) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    let display = discountPercent > 0
                        ? PayApi.discountedDisplay(major: major, percent: discountPercent, currency: currency)
                        : PayApi.formatPrice(major, currency: currency)
                    Text(display)
                        .font(.demarHeadlineMedium)
                        .foregroundStyle(Color.demarOnSurface)
                    if discountPercent > 0 {
                        Text(PayApi.formatPrice(major, currency: currency))
                            .font(.demarBodyMedium)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .strikethrough()
                    }
                }
            } else if loadingPlans {
                Text(String(localized: "Loading…"))
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    private func primaryButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.demarTitleMedium)
                .foregroundStyle(Color.demarOnPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.demarPrimary.opacity(enabled ? 1 : 0.45))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.demarTitleMedium)
                .foregroundStyle(Color.demarPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.demarPrimary.opacity(0.45), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    private func periodLabel(_ p: String) -> String {
        switch p {
        case "week": String(localized: "Week")
        case "month": String(localized: "Month")
        case "quarter": String(localized: "3 months")
        case "year": String(localized: "Year")
        default: p
        }
    }

    private func loadPlans() async {
        if let hit = PayApi.cachedPlans {
            catalog = hit
            loadingPlans = false
            return
        }
        guard catalog == nil else {
            loadingPlans = false
            return
        }
        loadingPlans = true
        plansError = nil
        defer { loadingPlans = false }
        do {
            catalog = try await PayApi.fetchPlans()
        } catch is CancellationError {
            return
        } catch {
            plansError = (error as? DemarAPIError)?.message
                ?? String(localized: "Couldn’t load plans")
            snackBar.showError(plansError!)
        }
    }

    private func applyPromo() async {
        guard let session = appState.authSession else { return }
        let code = promoCode.trimmingCharacters(in: .whitespacesAndNewlines)
        promoCode = ""
        guard !code.isEmpty else { return }
        do {
            let result = try await PromoApi.apply(
                code: code,
                userId: session.userId,
                loginAt: session.loginAt
            )
            promoResultMessage = result.localizedMessage
            if result.isApplied {
                appliedCode = code.uppercased()
                discountPercent = result.discountPercent ?? 0
            }
        } catch let e as DemarAPIError where e.statusCode == 429 {
            promoResultMessage = String(localized: "Please try again in 3 seconds")
        } catch {
            promoResultMessage = error.localizedDescription
        }
        showPromoResult = true
    }

    private func pay(tier selectedTier: String) async {
        guard let session = appState.authSession, !paying else { return }
        tier = selectedTier
        paying = true
        defer { paying = false }
        do {
            let checkout = try await PayApi.create(
                userId: session.userId,
                loginAt: session.loginAt,
                tier: selectedTier,
                period: period,
                currency: currency,
                code: appliedCode
            )
            onDismiss()
            AppPlatform.open(checkout.payUrl)
        } catch let e as DemarAPIError where e.isSessionInvalid {
            await appState.forceLocalSignOut()
        } catch let e as DemarAPIError where e.statusCode == 429 {
            snackBar.showInfo(String(localized: "Please try again in 3 seconds"))
        } catch {
            snackBar.showError(error.localizedDescription)
        }
    }
}

#if os(iOS)
private struct CheckoutSegmentBar: View {
    let options: [(String, String)]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { id, title in
                    let on = id == selectedID
                    Text(title)
                        .font(.demarTitleMedium)
                        .foregroundStyle(on ? Color.demarOnSurface : Color.demarOnSurfaceVariant)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(on ? Color.demarPrimary.opacity(0.18) : Color.clear)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        select(at: value.location.x, width: geo.size.width)
                    }
            )
        }
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.demarSurfaceContainerHighest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.demarOutline.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transaction { $0.disablesAnimations = true }
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard width > 0, !options.isEmpty else { return }
        let index = min(max(Int((x / width) * CGFloat(options.count)), 0), options.count - 1)
        let id = options[index].0
        guard id != selectedID else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { onSelect(id) }
        PlatformServices.lightImpact()
    }
}
#endif
