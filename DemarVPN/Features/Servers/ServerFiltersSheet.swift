import SwiftUI

struct ServerFiltersSheet: View {
    @Bindable var appState: AppState

    private var tiers: [ServerTier] { appState.servers.visibleTiers() }
    private var protocols: [ServerProtocol] { appState.servers.visibleProtocols() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterRow {
                ForEach(tiers, id: \.self) { tier in
                    filterChip(
                        label: tier.label,
                        checked: appState.filterTiers.contains(tier)
                    ) { on in
                        var next = appState.filterTiers
                        if on { next.insert(tier) } else { next.remove(tier) }
                        appState.setFilterTiers(next)
                    }
                }
            }
            filterRow {
                ForEach(protocols, id: \.self) { proto in
                    filterChip(
                        label: proto.label,
                        checked: appState.filterProtocols.contains(proto)
                    ) { on in
                        var next = appState.filterProtocols
                        if on { next.insert(proto) } else { next.remove(proto) }
                        appState.setFilterProtocols(next)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .demarSheetChrome(bottomPadding: 28)
    }

    private func filterRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
    }

    private func filterChip(label: String, checked: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Button {
            onChange(!checked)
        } label: {
            Text(label)
                .font(.demarTitleMediumBold)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(checked ? Color.demarOnSurface : Color.demarOnSurfaceVariant.opacity(0.65))
                .background(
                    checked
                        ? Color.demarSurfaceContainerHighest
                        : Color.demarSurfaceContainerHighest.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}
