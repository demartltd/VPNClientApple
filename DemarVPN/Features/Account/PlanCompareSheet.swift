import SwiftUI

struct PlanCompareSheet: View {
    var onBuy: () -> Void

    private var rows: [(label: String, free: CompareCell, plus: CompareCell, vip: CompareCell)] {
        [
            (String(localized: "Speed"), .text("10 Mbps"), .text("100 Mbps"), .text("300 Mbps")),
            (String(localized: "Traffic"), .text("5 GB"), .text("500 GB"), .text("3000 GB")),
            (String(localized: "Family invites*"), .bool(false), .text("2"), .text("4")),
            (String(localized: "Ad block"), .bool(false), .bool(true), .bool(true)),
            (String(localized: "TUN settings"), .bool(false), .bool(true), .bool(true)),
            (String(localized: "Dedicated IP*"), .bool(false), .bool(false), .bool(true)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Compare plans"))
                .font(.demarHeadlineMedium)
                .foregroundStyle(Color.demarOnSurface)

            VStack(spacing: 0) {
                headerRow
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    dataRow(row)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.demarOutline.opacity(0.2), lineWidth: 1)
            )

            Text(String(localized: "*Not available yet."))
                .font(.demarBodySmall)
                .foregroundStyle(Color.demarOnSurfaceVariant)

            Button(action: onBuy) {
                Text(String(localized: "Buy subscription"))
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

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["Free", "Plus", "VIP"], id: \.self) { name in
                Text(name)
                    .font(.demarLabelLarge)
                    .foregroundStyle(Color.demarOnSurface)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.demarSurfaceContainerHighest)
    }

    private func dataRow(_ row: (label: String, free: CompareCell, plus: CompareCell, vip: CompareCell)) -> some View {
        HStack(spacing: 0) {
            Text(row.label)
                .font(.demarBodySmall)
                .foregroundStyle(Color.demarOnSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            cellView(row.free)
            cellView(row.plus)
            cellView(row.vip)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.demarSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.demarOutline.opacity(0.15))
                .frame(height: 1)
        }
    }

    private func cellView(_ cell: CompareCell) -> some View {
        Group {
            switch cell {
            case .bool(true):
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.demarPrimary)
            case .bool(false):
                Text("—")
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant.opacity(0.55))
            case .text(let s):
                Text(s)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

enum CompareCell {
    case bool(Bool)
    case text(String)
}
