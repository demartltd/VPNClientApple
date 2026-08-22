import SwiftUI

struct TrafficPieChart: View {
    let servers: [VpnTrafficServer]
    let otherLabel: String
    let centerPrimary: String
    let accountId: String

    @State private var progress = 0.0

    private let chartSize: CGFloat = 144

    private var palette: [Color] {
        [
            .demarPrimary,
            .demarTertiary,
            .demarSecondary,
            .demarPrimary.opacity(0.55),
            .demarTertiary.opacity(0.55),
            .demarSecondary.opacity(0.55),
        ]
    }

    private var slices: [VpnTrafficServer] {
        VpnAccountApi.pieSlices(servers, otherLabel: otherLabel)
    }

    var body: some View {
        let slices = self.slices
        let hasData = slices.contains { $0.bytes > 0 }

        FloatEndFlow(spacing: 12, lineSpacing: 10, gap: 12) {
            Text(accountId)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .opacity(progress)
                .floatFullRow()

            if hasData {
                ForEach(Array(slices.enumerated()), id: \.element.id) { i, slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(palette[i % palette.count])
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(slice.name)
                                .font(.demarBodySmall)
                                .foregroundStyle(Color.demarOnSurface)
                            Text(VpnAccountApi.formatBytes(slice.bytes))
                                .font(.demarBodySmall)
                                .foregroundStyle(Color.demarOnSurfaceVariant)
                        }
                    }
                    .opacity(progress)
                }
            }

            ZStack {
                AnimatedPieRing(progress: progress, slices: slices, palette: palette)
                    .frame(width: chartSize, height: chartSize)
                    .rotationEffect(.degrees(-18 * (1 - progress)))
                Text(centerPrimary)
                    .font(.demarBodySmall)
                    .foregroundStyle(Color.demarOnSurface)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .opacity(0.35 + 0.65 * progress)
            }
            .frame(width: chartSize, height: chartSize)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
        )
        .onAppear {
            progress = 0
            withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.75)) {
                progress = 1
            }
        }
    }
}

/// Animatable ring — sweep grows like Android (`fullSweep * t`, start advances by full).
private struct AnimatedPieRing: View, Animatable {
    var progress: Double
    let slices: [VpnTrafficServer]
    let palette: [Color]

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let total = max(1, slices.reduce(Int64(0)) { $0 + $1.bytes })
        let hasData = slices.contains { $0.bytes > 0 }
        let t = progress

        Canvas { ctx, size in
            let stroke = min(size.width, size.height) * 0.18
            let diam = min(size.width, size.height) - stroke
            let origin = CGPoint(x: (size.width - diam) / 2, y: (size.height - diam) / 2)
            let rect = CGRect(origin: origin, size: CGSize(width: diam, height: diam))
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = diam / 2

            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
            ctx.stroke(track, with: .color(.demarSurfaceContainerHighest), style: StrokeStyle(lineWidth: stroke, lineCap: .butt))

            guard hasData else { return }
            var start = Angle.degrees(-90)
            for (i, slice) in slices.enumerated() {
                let full = Angle.degrees(Double(slice.bytes) / Double(total) * 360)
                let sweep = Angle.degrees(full.degrees * t)
                if sweep.degrees > 0.01 {
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: start,
                        endAngle: start + max(sweep, .degrees(0.5)),
                        clockwise: false
                    )
                    ctx.stroke(
                        path,
                        with: .color(palette[i % palette.count]),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .butt)
                    )
                }
                start += full
            }
        }
        .opacity(0.4 + 0.6 * t)
        .scaleEffect(0.86 + 0.14 * t)
    }
}

private struct FloatFullRowKey: LayoutValueKey {
    static let defaultValue = false
}

private extension View {
    func floatFullRow(_ value: Bool = true) -> some View {
        layoutValue(key: FloatFullRowKey.self, value: value)
    }
}

/// Leading flow with last subview floated top-trailing (CSS float:right).
private struct FloatEndFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal.replacingUnspecifiedDimensions().width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(bounds.width, subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        guard let floatIndex = subviews.indices.last else {
            return (.zero, [])
        }
        let floatSize = subviews[floatIndex].sizeThatFits(.unspecified)
        let floatX = max(0, width - floatSize.width)
        var origins = Array(repeating: CGPoint.zero, count: subviews.count)
        origins[floatIndex] = CGPoint(x: floatX, y: 0)

        let flow = subviews.indices.filter { $0 != floatIndex }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxY = floatSize.height

        for i in flow {
            let s = subviews[i].sizeThatFits(.unspecified)
            let fullRow = subviews[i][FloatFullRowKey.self]

            if fullRow {
                if x > 0 {
                    x = 0
                    y += rowH + lineSpacing
                    rowH = 0
                }
                origins[i] = CGPoint(x: 0, y: y)
                y += s.height + lineSpacing
                rowH = 0
                x = 0
                maxY = max(maxY, y)
                continue
            }

            let beside = y < floatSize.height
            let avail = beside ? max(0, floatX - gap) : width
            if x > 0, x + spacing + s.width > avail {
                x = 0
                y += rowH + lineSpacing
                rowH = 0
            }
            let lineAvail = (y < floatSize.height) ? max(0, floatX - gap) : width
            if s.width > lineAvail, lineAvail < width {
                x = 0
                y = max(y, floatSize.height + lineSpacing)
                rowH = 0
            }
            origins[i] = CGPoint(x: x, y: y)
            rowH = max(rowH, s.height)
            x += s.width + spacing
            maxY = max(maxY, y + s.height)
        }
        return (CGSize(width: width, height: maxY), origins)
    }
}
