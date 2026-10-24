import SwiftUI

struct ServerDetailsSheet: View {
    let profile: ServerProfile
    let reachState: ServerReachState
    let trafficBytes: Int64?
    let favorite: Bool
    var onToggleFavorite: () -> Void

    private var directCodes: [String] { profile.bypassRuleSets.directCountryCodes() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CountryFlagView(code: profile.countryCode, emoji: profile.flagEmoji)
                Text(profile.displayName)
                    .font(.demarTitleLarge)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.demarOnSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onToggleFavorite) {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .font(.system(size: 22))
                        .foregroundStyle(favorite ? Color.demarError : Color.demarOnSurfaceVariant)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favorite ? "Remove favorite" : "Add favorite")
            }
            .padding(.bottom, 12)

            HStack(spacing: 6) {
                ServerBadge(label: profile.tier.label, tier: profile.tier, large: true)
                ProtocolServerBadges(profile: profile, full: true, large: true)
            }
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Load"))
                        .font(.demarLabelLarge)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                    LoadBar(percent: profile.effectiveLoadPercent)
                }
                .padding(16)

                if profile.serverProtocol.showsUplinkPing {
                    metricRow("TCP", ServerReachState.formatMs(reachState.latencyMs), first: true)
                    metricRow(
                        ServerReachState.handshakeLabel(profile.serverProtocol),
                        ServerReachState.formatMs(reachState.tlsMs)
                    )
                    metricRow(
                        String(localized: "Traffic"),
                        trafficBytes.map(VpnAccountApi.formatBytes) ?? "—"
                    )
                } else {
                    metricRow(
                        String(localized: "Traffic"),
                        trafficBytes.map(VpnAccountApi.formatBytes) ?? "—",
                        first: true
                    )
                }
                if !directCodes.isEmpty {
                    Divider().overlay(Color.demarOutlineVariant.opacity(0.45)).padding(.horizontal, 12)
                    HStack {
                        Text(String(localized: "Direct"))
                            .font(.demarTitleMedium)
                            .foregroundStyle(Color.demarOnSurface)
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(directCodes, id: \.self) { code in
                                Text(ServerProfile.flagEmoji(forCountryCode: code))
                                    .font(.system(size: 22))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .background(Color.demarSurfaceContainerHighest, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .demarSheetChrome(bottomPadding: 28)
    }

    private func metricRow(_ label: String, _ value: String, first: Bool = false) -> some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.demarOutlineVariant.opacity(first ? 0.6 : 0.45))
                .padding(.horizontal, first ? 0 : 12)
            HStack {
                Text(label)
                    .font(.demarTitleMedium)
                    .foregroundStyle(Color.demarOnSurface)
                Spacer()
                Text(value)
                    .font(.demarTitleMedium)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.demarOnSurface)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

}

private struct LoadBar: View {
    let percent: Int

    var body: some View {
        let p = Double(percent.clamped(to: 0...100)) / 100
        let fill: Color = {
            if percent <= 50 { return Color.demarSecondary }
            if percent <= 80 { return Color.demarTertiary }
            return Color.demarError
        }()
        let track: Color = {
            if percent <= 50 { return Color.demarSecondary.opacity(0.25) }
            if percent <= 80 { return Color.demarTertiary.opacity(0.25) }
            return Color.demarErrorContainer
        }()
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(0, geo.size.width * p))
            }
        }
        .frame(height: 12)
        .accessibilityLabel("server_load_\(percent)")
    }
}

struct CountryFlagView: View {
    let code: String?
    let emoji: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.demarPrimary.opacity(0.1))
            if emoji.isEmpty {
                Text(code ?? "?")
                    .font(.demarBodySmall.weight(.bold))
                    .foregroundStyle(Color.demarPrimary)
            } else {
                Text(emoji)
                    .font(.system(size: size * 0.6))
            }
        }
        .frame(width: size, height: size)
    }
}
