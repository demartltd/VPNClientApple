import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SupportBubble: View {
    let message: SupportMessage
    let session: AuthSession
    let ticketId: String
    let canWrite: Bool
    var selected: Bool = false
    var onCopy: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onOpenMenu: () -> Void = {}

    var body: some View {
        let mine = message.isUser
        let photos = message.media.filter { $0.isPhoto && ($0.url?.nilIfBlank != nil) }
        let files = message.media.filter { !($0.isPhoto && ($0.url?.nilIfBlank != nil)) }
        let shape = bubbleShape(mine)
        let timeStr = formatSupportMsgTime(message.createdAt)

        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 48) }

            Group {
                if message.deleted {
                    Text("Message deleted")
                        .font(.demarBodySmall.italic())
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let text = message.text {
                            Text(AttributedString(linkified: text))
                                .font(.demarBodyMedium)
                                .foregroundStyle(Color.demarOnSurface)
                                // Keep system Look Up / Select / Translate off — bubble owns long-press.
                                .allowsHitTesting(false)
                        }
                        if !photos.isEmpty {
                            SupportPhotoAlbum(photos: photos, session: session, ticketId: ticketId)
                        }
                        ForEach(Array(files.enumerated()), id: \.offset) { _, med in
                            SupportFileRow(media: med)
                        }
                        if let timeStr {
                            Text(timeStr)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.demarOnSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: 260, alignment: .leading)
                }
            }
            .padding(10)
            .background(bubbleFill(mine), in: shape)
            .compositingGroup()
            .contentShape(shape)
            .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(selected ? 1.03 : 1)
            .shadow(color: selected ? Color.black.opacity(0.18) : .clear, radius: selected ? 12 : 0, y: 4)
            #if os(iOS)
            .onLongPressGesture(minimumDuration: 0.35) {
                onOpenMenu()
            }
            #else
            .contextMenu {
                if !message.deleted, message.text != nil {
                    Button(String(localized: "Copy"), action: onCopy)
                }
                if !message.deleted, canWrite, mine {
                    if message.text != nil {
                        Button(String(localized: "Edit"), action: onEdit)
                    }
                    Button(String(localized: "Delete"), role: .destructive, action: onDelete)
                }
            }
            #endif

            if !mine { Spacer(minLength: 48) }
        }
    }

    private func bubbleFill(_ mine: Bool) -> Color {
        mine ? Color.demarPrimary.opacity(0.22) : Color.demarSurfaceContainerHighest.opacity(0.7)
    }

    private func bubbleShape(_ mine: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: mine ? 16 : 4,
            bottomTrailingRadius: mine ? 4 : 16,
            topTrailingRadius: 16,
            style: .continuous
        )
    }
}

private struct SupportFileRow: View {
    let media: SupportMedia

    private var title: String {
        media.fileName ?? media.type ?? String(localized: "Attachment")
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.demarPrimary.opacity(0.18))
                Image(systemName: "doc.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.demarPrimary)
            }
            .frame(width: 42, height: 42)

            Text(title)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurface)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.demarSurface.opacity(0.45))
        )
    }
}

#if os(iOS)
struct SupportMessageMenuOverlay: View {
    let message: SupportMessage
    let session: AuthSession
    let ticketId: String
    let canWrite: Bool
    var onCopy: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onDismiss: () -> Void

    private var mine: Bool { message.isUser }
    private var hasText: Bool { !(message.text ?? "").isEmpty }
    private var canEdit: Bool { canWrite && mine && hasText && !message.deleted }
    private var canDelete: Bool { canWrite && mine && !message.deleted }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.28))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                SupportBubble(
                    message: message,
                    session: session,
                    ticketId: ticketId,
                    canWrite: false,
                    selected: true,
                    onCopy: {},
                    onEdit: {},
                    onDelete: {}
                )
                .allowsHitTesting(false)

                HStack(spacing: 0) {
                    if mine { Spacer(minLength: 48) }
                    VStack(spacing: 0) {
                        if hasText {
                            menuRow(String(localized: "Copy"), systemImage: "doc.on.doc", role: nil, action: onCopy)
                        }
                        if canEdit {
                            if hasText { menuDivider }
                            menuRow(String(localized: "Edit"), systemImage: "pencil", role: nil, action: onEdit)
                        }
                        if canDelete {
                            if hasText || canEdit { menuDivider }
                            menuRow(String(localized: "Delete"), systemImage: "trash", role: .destructive, action: onDelete)
                        }
                    }
                    .frame(width: 260)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.demarOnSurface.opacity(0.12), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
                    if !mine { Spacer(minLength: 48) }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var menuDivider: some View {
        Divider().opacity(0.35)
    }

    private func menuRow(
        _ title: String,
        systemImage: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.demarBodyMedium)
                    .foregroundStyle(role == .destructive ? Color.demarError : Color.demarOnSurface)
                Spacer(minLength: 12)
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(role == .destructive ? Color.demarError : Color.demarOnSurfaceVariant)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif

struct SupportPhotoAlbum: View {
    let photos: [SupportMedia]
    let session: AuthSession
    let ticketId: String

    private let gap: CGFloat = 3
    private let maxWidth: CGFloat = 260

    var body: some View {
        let count = photos.count
        let cols = columnCount(for: count)
        let thumbW = (maxWidth - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let thumbH = maxThumbHeight(for: count)
        let rows = stride(from: 0, to: count, by: cols).map {
            Array(photos[$0..<min($0 + cols, count)])
        }

        if count == 1 {
            SupportMediaThumb(
                media: photos[0],
                session: session,
                ticketId: ticketId,
                maxWidth: maxWidth,
                maxHeight: 220
            )
        } else {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, photo in
                            SupportMediaThumb(
                                media: photo,
                                session: session,
                                ticketId: ticketId,
                                maxWidth: thumbW,
                                maxHeight: thumbH
                            )
                        }
                    }
                }
            }
        }
    }

    private func columnCount(for count: Int) -> Int {
        switch count {
        case 2...4: return 2
        case 5...9: return 3
        default: return 4
        }
    }

    private func maxThumbHeight(for count: Int) -> CGFloat {
        switch count {
        case 2: return 140
        case 3, 4: return 110
        case 5, 6: return 88
        case 7...9: return 72
        default: return 58
        }
    }
}

struct SupportMediaThumb: View {
    let media: SupportMedia
    let session: AuthSession
    let ticketId: String
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    @State private var image: PlatformImage?
    @State private var aspect: CGFloat?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                #else
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                #endif
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(Color.demarOnSurfaceVariant)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: media.url) {
            guard let path = media.url, image == nil else { return }
            if let w = media.width, let h = media.height, w > 0, h > 0 {
                aspect = CGFloat(w) / CGFloat(h)
            }
            do {
                let data = try await SupportApi.loadMediaBytes(
                    userId: session.userId,
                    loginAt: session.loginAt,
                    mediaPath: path,
                    ticketId: ticketId
                )
                #if os(iOS)
                let img = UIImage(data: data)
                image = img
                if let img, img.size.height > 0 {
                    aspect = img.size.width / img.size.height
                }
                #else
                let img = NSImage(data: data)
                image = img
                if let img, img.size.height > 0 {
                    aspect = img.size.width / img.size.height
                }
                #endif
                if image == nil { failed = true }
            } catch {
                failed = true
            }
        }
    }

    private var frameSize: CGSize {
        let r = max(0.25, aspect ?? (media.width.flatMap { w in
            media.height.map { CGFloat(w) / CGFloat($0) }
        } ?? 4 / 3))
        var w = maxWidth
        var h = w / r
        if h > maxHeight {
            h = maxHeight
            w = h * r
            if w > maxWidth {
                w = maxWidth
                h = w / r
            }
        }
        return CGSize(width: w, height: h)
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif
