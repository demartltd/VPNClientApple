import SwiftUI

struct SettingsLinksStrip: View {
    var body: some View {
        SocialLinksWrap(spacing: 12) {
            ForEach(Array(FontAwesomeBrands.links.enumerated()), id: \.offset) { _, link in
                Link(destination: link.url) {
                    BrandIconView(glyph: link.glyph)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.demarPrimary.opacity(0.10))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Centered wrap — Flutter `Wrap(alignment: WrapAlignment.center)`.
private struct SocialLinksWrap: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGRect]] = [[]]
        var rowSizes: [CGSize] = [.zero]
        var x: CGFloat = 0
        var y: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                rows.append([])
                rowSizes.append(.zero)
                x = 0
                y += rowSizes[rows.count - 2].height + spacing
            }
            let rowIndex = rows.count - 1
            rows[rowIndex].append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowSizes[rowIndex].width = max(rowSizes[rowIndex].width, x + size.width)
            rowSizes[rowIndex].height = max(rowSizes[rowIndex].height, size.height)
            x += size.width + spacing
        }

        var frames: [CGRect] = []
        var offsetY: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let rowWidth = rowSizes[rowIndex].width
            let rowHeight = rowSizes[rowIndex].height
            let insetX = max(0, (min(maxWidth, rowWidth) - rowWidth) / 2)
            for frame in row {
                frames.append(CGRect(
                    x: frame.minX + insetX,
                    y: offsetY,
                    width: frame.width,
                    height: frame.height
                ))
            }
            offsetY += rowHeight + spacing
        }

        let height = max(0, offsetY - (rows.isEmpty ? 0 : spacing))
        return (CGSize(width: min(maxWidth, rowSizes.map(\.width).max() ?? 0), height: height), frames)
    }
}
