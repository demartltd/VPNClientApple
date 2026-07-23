import SwiftUI
#if os(iOS)
import UIKit

enum DynamicIsland {
    /// iPhone with notch or Dynamic Island (top inset ≥ 47); notch hides the pill on non-DI hardware.
    static var showsBadge: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        return topSafeInset >= 47
    }

    /// Vertical offset from screen top to align pill with the hardware cutout.
    static var badgeTopPadding: CGFloat {
        if !hasDynamicIsland { return 1 } // notch — higher, hidden by hardware
        if modelCode == "iPhone18,4" { return 21 } // Air
        return 14
    }

    private static var hasDynamicIsland: Bool { topSafeInset >= 51 }

    private static var topSafeInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.top
            ?? scenes.flatMap(\.windows).map(\.safeAreaInsets.top).max()
            ?? 0
    }

    private static var modelCode: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var uts = utsname()
        guard uname(&uts) == 0 else { return "" }
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

struct DynamicIslandBadge: View {
    var topPadding: CGFloat = DynamicIsland.badgeTopPadding

    var body: some View {
        Text("DEMAR VPN")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(Color.demarPrimary)
            .shadow(color: Color.demarOnPrimaryContainer.opacity(0.55), radius: 0, x: 0, y: -0.7)
            .shadow(color: Color.demarOnPrimary.opacity(0.85), radius: 0, x: 0, y: 0.8)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(Capsule().fill(Color.demarPrimaryContainer))
            .padding(.top, topPadding)
            .accessibilityHidden(true)
    }
}

private struct DynamicIslandBadgeModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsBadge = false
    @State private var suppressed = false

    private var visible: Bool { showsBadge && scenePhase == .active && !suppressed }

    func body(content: Content) -> some View {
        content
            .overlay {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if visible {
                            DynamicIslandBadge()
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .onAppear { refreshBadge() }
            .onChange(of: scenePhase) { _, phase in
                suppressed = phase != .active
                if phase == .active { refreshBadge() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                suppressed = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                suppressed = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                suppressed = false
                refreshBadge()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                suppressed = false
                refreshBadge()
            }
    }

    private func refreshBadge() {
        showsBadge = DynamicIsland.showsBadge
    }
}

extension View {
    func demarDynamicIslandBadge() -> some View {
        modifier(DynamicIslandBadgeModifier())
    }
}
#endif
