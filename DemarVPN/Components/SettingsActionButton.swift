import SwiftUI

struct SettingsActionButton<Trailing: View, Extra: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var danger: Bool
    var showsChevron: Bool
    var unread: Bool
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var extra: () -> Extra

    private var accent: Color { danger ? .demarError : .demarPrimary }

    var body: some View {
        HStack(spacing: 16) {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }

            trailing()
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
    }

    private var label: some View {
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
                HStack(spacing: 8) {
                    if unread {
                        Circle()
                            .fill(Color.demarPrimary)
                            .frame(width: 8, height: 8)
                    }
                    Text(title)
                        .font(.demarTitleMedium)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.demarOnSurface)
                }
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
        .contentShape(Rectangle())
    }
}

extension SettingsActionButton where Trailing == EmptyView, Extra == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String,
        danger: Bool = false,
        showsChevron: Bool = false,
        unread: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            danger: danger,
            showsChevron: showsChevron,
            unread: unread,
            action: action,
            trailing: { EmptyView() },
            extra: { EmptyView() }
        )
    }
}

extension SettingsActionButton where Trailing == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String,
        danger: Bool = false,
        showsChevron: Bool = false,
        unread: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder extra: @escaping () -> Extra
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            danger: danger,
            showsChevron: showsChevron,
            unread: unread,
            action: action,
            trailing: { EmptyView() },
            extra: extra
        )
    }
}

extension SettingsActionButton where Extra == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String,
        danger: Bool = false,
        showsChevron: Bool = false,
        unread: Bool = false,
        action: (() -> Void)?,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            danger: danger,
            showsChevron: showsChevron,
            unread: unread,
            action: action,
            trailing: trailing,
            extra: { EmptyView() }
        )
    }
}
