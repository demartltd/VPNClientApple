import SwiftUI

struct ServerBadge: View {
    let label: String
    var tier: ServerTier? = nil
    var large: Bool = false

    var body: some View {
        let (bg, fg) = colors
        Text(label)
            .font(.system(size: large ? 12 : 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, large ? 8 : 4)
            .padding(.vertical, large ? 0 : 1)
            .frame(height: large ? 24 : nil)
            .background(bg, in: RoundedRectangle(cornerRadius: large ? 6 : 4, style: .continuous))
    }

    private var colors: (Color, Color) {
        switch tier {
        case .plus:
            return (Color.green.opacity(0.28), Color.green.opacity(0.95))
        case .vip:
            return (Color.purple.opacity(0.28), Color.purple.opacity(0.95))
        default:
            return (Color.demarOnSurface.opacity(0.10), Color.demarOnSurfaceVariant)
        }
    }
}

struct FavoriteServerBadge: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 12))
            .foregroundStyle(Color.demarError)
            .frame(width: 24, height: 24)
            .background(Color.demarError.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Home SelectedServerLabel badges — Android FlowRow: `<3` → 1/row, `>=3` → 2/row.
struct ServerHomeBadgeGrid: View {
    let profile: ServerProfile
    let favorite: Bool

    var body: some View {
        // badgeCount = 2 + (favorite ? 1 : 0); badgesPerRow = badgeCount >= 3 ? 2 : 1
        VStack(alignment: .leading, spacing: 4) {
            if favorite {
                HStack(spacing: 4) {
                    FavoriteServerBadge()
                    ServerBadge(label: profile.tier.label, tier: profile.tier, large: true)
                }
                ServerBadge(label: profile.protocolLabel, large: true)
            } else {
                ServerBadge(label: profile.tier.label, tier: profile.tier, large: true)
                ServerBadge(label: profile.protocolLabel, large: true)
            }
        }
    }
}
