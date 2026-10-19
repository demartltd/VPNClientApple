import SwiftUI

struct ServerFiltersSheet: View {
    @Bindable var appState: AppState

    private let gap: CGFloat = 8

    /// Tier then protocol — one flow, max 3 / row (Android `FlowRow` parity).
    private var items: [FilterItem] {
        appState.servers.visibleTiers().map(FilterItem.tier)
            + appState.servers.visibleProtocols().map(FilterItem.proto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Self.rows(items), id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(row, id: \.self) { item in
                        chip(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .demarSheetChrome(bottomPadding: 28)
    }

    private static func rows(_ items: [FilterItem]) -> [[FilterItem]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0..<min($0 + 3, items.count)])
        }
    }

    private func chip(_ item: FilterItem) -> some View {
        let on: Bool = {
            switch item {
            case .tier(let t): appState.filterTiers.contains(t)
            case .proto(let p): appState.filterProtocols.contains(p)
            }
        }()
        return Button {
            switch item {
            case .tier(let t):
                var next = appState.filterTiers
                if on { next.remove(t) } else { next.insert(t) }
                appState.setFilterTiers(next)
            case .proto(let p):
                var next = appState.filterProtocols
                if on { next.remove(p) } else { next.insert(p) }
                appState.setFilterProtocols(next)
            }
        } label: {
            Text(item.label)
                .font(.demarTitleMediumBold)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(on ? Color.demarOnSurface : Color.demarOnSurfaceVariant.opacity(0.65))
                .background(
                    on ? Color.demarSurfaceContainerHighest : Color.demarSurfaceContainerHighest.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

private enum FilterItem: Hashable {
    case tier(ServerTier), proto(ServerProtocol)

    var label: String {
        switch self {
        case .tier(let t): t.label
        case .proto(let p): p.label
        }
    }
}
