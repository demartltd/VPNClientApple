import SwiftUI

struct SectionCard<Leading: View, Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var bodyTopSpacing: CGFloat
    var onHeaderTap: (() -> Void)?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        bodyTopSpacing: CGFloat = 12,
        onHeaderTap: (() -> Void)? = nil,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.bodyTopSpacing = bodyTopSpacing
        self.onHeaderTap = onHeaderTap
        self.leading = leading
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            content()
                .padding(.top, bodyTopSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.demarSurfaceContainerHighest)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var headerRow: some View {
        let row = HStack(alignment: .top, spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.demarTitleMediumBold)
                    .foregroundStyle(Color.demarOnSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(.demarBodySmall)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .contentShape(Rectangle())

        if let onHeaderTap {
            Button(action: onHeaderTap) { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            row
        }
    }
}

extension SectionCard where Leading == EmptyView, Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: { EmptyView() }, content: content)
    }
}
