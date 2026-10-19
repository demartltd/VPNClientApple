import SwiftUI

struct ServerFiltersSheet: View {
    @Bindable var appState: AppState

    private var tiers: [ServerTier] { appState.servers.visibleTiers() }
    private var protocols: [ServerProtocol] { appState.servers.visibleProtocols() }

    private let gap: CGFloat = 8

    var body: some View {
        // Equal row/column gap (Android FlowRow / LazyVerticalGrid).
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Self.rows(tiers), id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(row, id: \.self) { tier in
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
            }
            ForEach(Self.rows(protocols), id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(row, id: \.self) { proto in
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .demarSheetChrome(bottomPadding: 28)
    }

    /// Max 3 chips/row; leftover row stretches via `maxWidth: .infinity` on each chip.
    private static func rows<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0..<min($0 + 3, items.count)])
        }
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
