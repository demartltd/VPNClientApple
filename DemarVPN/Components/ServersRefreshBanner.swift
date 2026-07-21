import SwiftUI

/// Top banner while servers refresh (foreground-visible).
struct ServersRefreshBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Обновление")
                .font(.demarLabelLarge)
                .foregroundStyle(Color.demarOnSurface)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.demarSurfaceContainerHighest)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.demarOutline.opacity(0.2), lineWidth: 1)
        )
        .accessibilityLabel("Обновление серверов")
    }
}
