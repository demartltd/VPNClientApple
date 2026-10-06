import Foundation
import Observation
#if os(iOS) || os(macOS)
import NetworkExtension
#endif
#if os(iOS)
import WidgetKit
#endif

@MainActor
extension AppState {
    func openCheckout(_ intent: CheckoutIntent) {
        guard isSignedIn else { return }
        showPlanCompare = false
        checkoutIntent = intent
    }

    func dismissCheckout() {
        checkoutIntent = nil
    }

    func handlePayReturn(success: Bool) {
        dismissCheckout()
        showPlanCompare = false
        accountRouteRequestTick &+= 1
        payResult = success ? .success : .failure
        // Fail: UI only. Ok: one silent refresh (servers/account/traffic/unread). No pay/status.
        guard success else { return }
        let now = Date()
        if let last = lastPayReturnRefreshAt, now.timeIntervalSince(last) < 5 { return }
        lastPayReturnRefreshAt = now
        Task { await refreshSessionData(force: true) }
    }

    func dismissPayResult() {
        payResult = nil
    }

    func openPlanCompare() {
        checkoutIntent = nil
        showPlanCompare = true
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
        case .traffic: pendingOpenTrafficSheet = true
        case .buy: openCheckout(.buy)
        case .plans: openPlanCompare()
        }
    }

    func presentPendingAccountSheetIfNeeded() {
        guard isSignedIn, let sheet = pendingAccountSheet else { return }
        pendingAccountSheet = nil
        if sheet == .traffic { accountRouteRequestTick &+= 1 }
        presentAccountSheet(sheet)
    }

    @discardableResult
    func consumePendingSettingsRoute() -> SettingsRoute? {
        defer { pendingSettingsRoute = nil }
        return pendingSettingsRoute
    }

    @discardableResult
    func consumeOpenTrafficSheetRequest() -> Bool {
        defer { pendingOpenTrafficSheet = false }
        return pendingOpenTrafficSheet
    }
}
