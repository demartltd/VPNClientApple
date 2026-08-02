import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
private enum SnackBarLayout {
    static let spacing: CGFloat = 8
    static let defaultTabBarHeight: CGFloat = 86

    /// Physical bottom inset: home indicator + tab bar + spacing (not SwiftUI layout during animation).
    static func bottomPadding() -> CGFloat {
        guard let window = UIWindowScene.activeKeyWindow else {
            return defaultTabBarHeight + spacing
        }
        let tabH = window.rootViewController?.embeddedTabBarHeight ?? defaultTabBarHeight
        return window.safeAreaInsets.bottom + tabH + spacing
    }
}
#else
private enum SnackBarLayout {
    static func bottomPadding() -> CGFloat { 16 }
}
#endif

enum DemarSnackKind: CaseIterable {
    case info, success, error, warning

    var tint: Color {
        switch self {
        case .info: .demarPrimary
        case .success: .demarSecondary
        case .error: .demarError
        case .warning: .demarTertiary
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var duration: TimeInterval { self == .error ? 5 : 2 }
}

@Observable
final class SnackBarController {
    var message: String?
    var kind: DemarSnackKind = .info
    private var hideTask: Task<Void, Never>?
    private var dismissGeneration = 0

    func show(_ text: String, kind: DemarSnackKind) {
        hideTask?.cancel()
        dismissGeneration += 1
        let generation = dismissGeneration
        let trimmed = String(text.prefix(256))
        message = trimmed.count < text.count ? trimmed + "…" : trimmed
        self.kind = kind
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(kind.duration))
            guard !Task.isCancelled, dismissGeneration == generation else { return }
            message = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        dismissGeneration += 1
        message = nil
    }

    func showInfo(_ text: String) { show(text, kind: .info) }
    func showSuccess(_ text: String) { show(text, kind: .success) }
    func showError(_ text: String) { show(text, kind: .error) }
    func showWarning(_ text: String) { show(text, kind: .warning) }
}

struct DemarSnackBarModifier: ViewModifier {
    @Bindable var controller: SnackBarController
    #if os(iOS)
    @State private var bottomPadding = SnackBarLayout.bottomPadding()
    #endif

    func body(content: Content) -> some View {
        content.overlay {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let message = controller.message {
                        DemarToast(message: message, kind: controller.kind) {
                            PlatformServices.copyToPasteboard(message)
                            PlatformServices.lightImpact()
                        } onDismiss: { controller.dismiss() }
                        .padding(.horizontal, 16)
                        #if os(iOS)
                        .padding(.bottom, bottomPadding)
                        #else
                        .padding(.bottom, SnackBarLayout.bottomPadding())
                        #endif
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(controller.message != nil)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: controller.message != nil)
        #if os(iOS)
        .onAppear { bottomPadding = SnackBarLayout.bottomPadding() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            bottomPadding = SnackBarLayout.bottomPadding()
        }
        #endif
    }
}

private struct DemarToast: View {
    let message: String
    let kind: DemarSnackKind
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var dragY: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 22))
                .foregroundStyle(kind.tint)
            Text(message)
                .font(.demarLabelLarge)
                .foregroundStyle(Color.demarOnSurface)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.demarOnSurface.opacity(0.08), lineWidth: 0.5)
        }
        .offset(y: max(0, dragY))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragY = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > 44 || value.predictedEndTranslation.height > 120 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.32)) { dragY = 0 }
                    }
                }
        )
        .onTapGesture(perform: onCopy)
        .onChange(of: message) { _, _ in dragY = 0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Tap to copy. Swipe down to dismiss."))
        .animation(nil, value: message)
    }
}

#if os(iOS)
private extension UIWindowScene {
    static var activeKeyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow
    }
}

private extension UIViewController {
    var embeddedTabBarHeight: CGFloat? {
        if let tbc = self as? UITabBarController { return tbc.tabBar.frame.height }
        for child in children {
            if let h = child.embeddedTabBarHeight { return h }
        }
        return nil
    }
}
#endif

extension View {
    func demarSnackBar(_ controller: SnackBarController) -> some View {
        modifier(DemarSnackBarModifier(controller: controller))
    }
}
