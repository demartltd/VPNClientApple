import SwiftUI

struct SubscriptionInfoSheet: View {
    let kind: SubscriptionAlertKind
    let highlight: String
    var onAction: () -> Void

    private var title: String {
        switch kind {
        case .expiry: String(localized: "Subscription is expiring!")
        case .freeTraffic: String(localized: "Buy a subscription")
        }
    }

    private var bodyText: String {
        switch kind {
        case .expiry: String(localized: "You will lose internet in")
        case .freeTraffic: String(localized: "Free version expires in")
        }
    }

    private var cta: String {
        switch kind {
        case .expiry: String(localized: "Renew subscription")
        case .freeTraffic: String(localized: "Buy subscription")
        }
    }

    /// FreeTraffic: Now ✗ → After ✓. Expiry: Now ✓ → After ✗.
    private var afterPositive: Bool { kind == .freeTraffic }

    private var features: [String] {
        [
            String(localized: "Secure internet"),
            String(localized: "Ad block"),
            String(localized: "TUN settings"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    Text(bodyText)
                        .font(.demarTitleMedium)
                        .foregroundStyle(Color.demarOnSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(highlight)
                        .font(.demarTitleLarge)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.demarError)
                        .multilineTextAlignment(.center)
                        .frame(minWidth: 88, alignment: .center)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                divider

                HStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity)
                    colHeader(String(localized: "Now"))
                    colHeader(String(localized: "After"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                divider

                ForEach(Array(features.enumerated()), id: \.offset) { index, label in
                    featureRow(label)
                    if index < features.count - 1 {
                        divider.padding(.horizontal, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.demarSurfaceContainerHighest)
            )

            Button(action: onAction) {
                Text(cta)
                    .font(.demarTitleMedium)
                    .foregroundStyle(Color.demarOnPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.demarPrimary)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .demarSheetChrome(bottomPadding: 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.demarOutline.opacity(0.35))
            .frame(height: 1)
    }

    private func colHeader(_ title: String) -> some View {
        Text(title)
            .font(.demarBodySmall)
            .fontWeight(.semibold)
            .foregroundStyle(Color.demarOnSurface)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private func featureRow(_ label: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            statusIcon(positive: !afterPositive)
            statusIcon(positive: afterPositive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func statusIcon(positive: Bool) -> some View {
        Image(systemName: positive ? "checkmark" : "xmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(positive ? Color.demarPrimary : Color.demarError)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
