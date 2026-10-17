import SwiftUI

enum SubscriptionAlertKind: Equatable {
    case expiry
    case freeTraffic
}

/// Single active account/pay sheet (Android `AppSheet` parity).
enum AccountFlowSheet: Equatable {
    case traffic
    case plans
    case checkout(CheckoutIntent)
    case payResult(PayFeedback)
    case alert(SubscriptionAlertKind)
}

@MainActor
extension AppState {
    func dismissAccountSheet() {
        accountSheet = nil
    }

    func openCheckout(_ intent: CheckoutIntent) {
        guard isSignedIn else { return }
        accountSheet = .checkout(intent)
    }

    func openPlanCompare() {
        accountSheet = .plans
    }

    func openTrafficSheet() {
        guard isSignedIn else { return }
        accountSheet = .traffic
    }

    func openSubscriptionAlert(_ kind: SubscriptionAlertKind) {
        guard isSignedIn else { return }
        accountSheet = .alert(kind)
    }

    /// Service menu / preview — UI only, no API.
    func presentPayResult(success: Bool) {
        accountSheet = .payResult(success ? .success : .failure)
    }

    func handlePayReturn(success: Bool) {
        accountRouteRequestTick &+= 1
        presentPayResult(success: success)
        guard success else { return }
        let now = Date()
        if let last = lastPayReturnRefreshAt, now.timeIntervalSince(last) < 5 { return }
        lastPayReturnRefreshAt = now
        Task { await refreshSessionData(force: true) }
    }

    /// Paid → traffic pie; free → FreeTraffic upsell.
    func openTrafficOrFreeAlert() {
        if isFreeSubscription {
            openSubscriptionAlert(.freeTraffic)
        } else {
            openTrafficSheet()
        }
    }

    func openAccountSheet(_ sheet: DemarDeepLink.AccountSheet) {
        accountRouteRequestTick &+= 1
        guard isSignedIn else {
            pendingAccountSheet = sheet
            return
        }
        presentAccountSheet(sheet)
    }

    func presentAccountSheet(_ sheet: DemarDeepLink.AccountSheet) {
        switch sheet {
        case .traffic: openTrafficSheet()
        case .buy: openCheckout(.buy)
        case .plans: openPlanCompare()
        }
    }

    func presentPendingAccountSheetIfNeeded() {
        guard isSignedIn, let sheet = pendingAccountSheet else { return }
        pendingAccountSheet = nil
        accountRouteRequestTick &+= 1
        presentAccountSheet(sheet)
    }

    @discardableResult
    func consumePendingSettingsRoute() -> SettingsRoute? {
        defer { pendingSettingsRoute = nil }
        return pendingSettingsRoute
    }

    /// Cached account/traffic only — call on scene active (like update alert).
    func evaluateSubscriptionAlerts() {
        guard isSignedIn, accountSheet == nil else { return }

        if !isFreeSubscription {
            let exp = account?.vpnExpiresAt ?? authSession?.vpnExpiresAt
            guard let exp, SubscriptionAlertStore.shouldShowExpiry(exp),
                  SubscriptionAlertStore.canShowExpiry()
            else { return }
            SubscriptionAlertStore.markExpiryShown()
            accountSheet = .alert(.expiry)
            return
        }

        guard let t = traffic,
              SubscriptionAlertStore.shouldShowTraffic(usedBytes: t.total),
              SubscriptionAlertStore.canShowTraffic()
        else { return }
        SubscriptionAlertStore.markTrafficShown()
        accountSheet = .alert(.freeTraffic)
    }

    func subscriptionAlertHighlight(for kind: SubscriptionAlertKind) -> String {
        switch kind {
        case .expiry:
            let iso = account?.vpnExpiresAt ?? authSession?.vpnExpiresAt
            if let iso, let ms = SubscriptionAlertStore.millisUntilExpiry(iso), ms > 0 {
                return SubscriptionAlertStore.formatRemaining(ms)
            }
            return SubscriptionAlertStore.formatRemaining(2 * 60 * 60 * 1000)
        case .freeTraffic:
            if let t = traffic {
                return VpnAccountApi.formatBytes(max(0, t.limitBytes - t.total))
            }
            return VpnAccountApi.formatBytes(500 * 1024 * 1024)
        }
    }

    /// Binding for one `AccountFlowSheet` case in `demarBottomSheet`.
    func accountSheetBinding(match: @escaping (AccountFlowSheet) -> Bool) -> Binding<Bool> {
        Binding(
            get: { self.accountSheet.map(match) ?? false },
            set: { if !$0 { self.accountSheet = nil } }
        )
    }
}
