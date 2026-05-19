import SwiftUI

/// List row card — same chrome as [ServersView].
struct DemarCardRow<Leading: View>: View {
    @ViewBuilder var leading: () -> Leading
    let title: String
    var subtitle: String?
    var showChevron = false

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarOnSurface)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.demarBodySmall)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.demarOnSurface.opacity(0.5))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.demarSurfaceContainerHighest)
        )
    }
}

/// Opaque top mask so scroll content does not show under the status bar / Dynamic Island.
struct DemarTopScrollCurtain: View {
    var body: some View {
        Color.demarSurface
            .frame(maxWidth: .infinity)
            .frame(height: 0)
            .background(Color.demarSurface.ignoresSafeArea(edges: .top))
            .allowsHitTesting(false)
    }
}

extension View {
    func demarScrollScreen() -> some View {
        scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color.demarSurface)
            .overlay(alignment: .top) { DemarTopScrollCurtain() }
    }

    func demarListScreen() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.top, 12)
            .padding(.bottom, 24)
    }

    func demarListRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
