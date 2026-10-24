import SwiftUI

struct ServerBadge: View {
    let label: String
    var tier: ServerTier? = nil
    var whiteList: Bool = false
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
        if whiteList {
            return (Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x6E / 255),
                    Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255))
        }
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

/// Protocol chips; OpenFlux keeps White List + SOCKS in one row.
struct ProtocolServerBadges: View {
    let profile: ServerProfile
    var full: Bool = false
    var large: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(profile.protocolBadges(full: full).enumerated()), id: \.offset) { _, spec in
                ServerBadge(label: spec.label, whiteList: spec.whiteList, large: large)
            }
        }
    }
}

/// Home SelectedServerLabel badges — Android FlowRow: `<3` → 1/row, `>=3` → 2/row.
struct ServerHomeBadgeGrid: View {
    let profile: ServerProfile
    let favorite: Bool

    var body: some View {
        let proto = profile.protocolBadges(full: false)
        let total = 1 + proto.count + (favorite ? 1 : 0)
        let twoCol = total >= 3
        VStack(alignment: .leading, spacing: 4) {
            if twoCol {
                HStack(spacing: 4) {
                    if favorite { FavoriteServerBadge() }
                    ServerBadge(label: profile.tier.label, tier: profile.tier, large: true)
                }
                ProtocolServerBadges(profile: profile, large: true)
            } else {
                ServerBadge(label: profile.tier.label, tier: profile.tier, large: true)
                ProtocolServerBadges(profile: profile, large: true)
            }
        }
    }
}
