import SwiftUI

struct SettingsActionButton<Extra: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var danger: Bool
    var showsChevron: Bool
    let action: () -> Void
    @ViewBuilder var extra: () -> Extra

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        danger: Bool = false,
        showsChevron: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder extra: @escaping () -> Extra
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.danger = danger
        self.showsChevron = showsChevron
        self.action = action
        self.extra = extra
    }

    private var accent: Color { danger ? .demarError : .demarPrimary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accent.opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.demarTitleMedium)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.demarOnSurface)
                    Text(subtitle)
                        .font(.demarBodySmall)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                    extra()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.demarSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension SettingsActionButton where Extra == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String,
        danger: Bool = false,
        showsChevron: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            danger: danger,
            showsChevron: showsChevron,
            action: action,
            extra: { EmptyView() }
        )
    }
}
