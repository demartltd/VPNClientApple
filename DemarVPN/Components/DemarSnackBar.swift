import SwiftUI

#if os(iOS)
private let snackBarChromeInset: CGFloat = 49
#else
private let snackBarChromeInset: CGFloat = 0
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

    func show(_ text: String, kind: DemarSnackKind) {
        hideTask?.cancel()
        let trimmed = String(text.prefix(256))
        message = trimmed.count < text.count ? trimmed + "…" : trimmed
        self.kind = kind
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(kind.duration))
            if !Task.isCancelled { self.message = nil }
        }
    }

    func dismiss() {
        hideTask?.cancel()
        message = nil
    }

    func showInfo(_ text: String) { show(text, kind: .info) }
    func showSuccess(_ text: String) { show(text, kind: .success) }
    func showError(_ text: String) { show(text, kind: .error) }
    func showWarning(_ text: String) { show(text, kind: .warning) }
}

struct DemarSnackBarModifier: ViewModifier {
    @Bindable var controller: SnackBarController

    func body(content: Content) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                content
                    .frame(width: geo.size.width, height: geo.size.height)

                if let message = controller.message {
                    DemarToast(message: message, kind: controller.kind) {
                        PlatformServices.copyToPasteboard(message)
                        PlatformServices.lightImpact()
                    } onDismiss: {
                        controller.dismiss()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, geo.safeAreaInsets.bottom + snackBarChromeInset + 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: controller.message)
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
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Нажмите, чтобы скопировать. Смахните вниз, чтобы скрыть.")
    }
}

extension View {
    func demarSnackBar(_ controller: SnackBarController) -> some View {
        modifier(DemarSnackBarModifier(controller: controller))
    }
}
