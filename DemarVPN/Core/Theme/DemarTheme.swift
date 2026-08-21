import SwiftUI

/// Dark theme aligned with Flutter M3 seed `#3A6EA5`, shared across iOS and macOS.
enum Demar {
    enum Color {
        static let accent = rgb(0.643, 0.788, 1)
        static let onAccent = rgb(0, 0.192, 0.357)
        static let accentMuted = rgb(0, 0.282, 0.506)
        static let onAccentMuted = rgb(0.827, 0.894, 1)
        /// Switch track ON — richer seed-family blue (not M3 light primary).
        static let toggle = rgb(0.310, 0.529, 0.753) // #4F87C0

        static let background = rgb(0.063, 0.078, 0.094)
        static let card = rgb(0.204, 0.224, 0.255)
        static let label = rgb(0.878, 0.886, 0.910)
        static let secondaryLabel = rgb(0.765, 0.776, 0.812)
        static let separator = rgb(0.553, 0.569, 0.600)

        static let success = rgb(0.733, 0.780, 0.859)
        static let onSuccess = rgb(0.145, 0.192, 0.251)
        static let warning = rgb(0.839, 0.745, 0.894)
        static let onWarning = rgb(0.231, 0.161, 0.282)
        static let danger = rgb(1, 0.706, 0.671)
        static let onDanger = rgb(0.412, 0, 0.020)
        static let dangerMuted = rgb(0.576, 0, 0.039)
        static let onDangerMuted = rgb(1, 0.855, 0.839)

        private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> SwiftUI.Color {
            SwiftUI.Color(red: r, green: g, blue: b)
        }
    }

    enum Font {
        static let headline = SwiftUI.Font.system(size: 28, weight: .regular)
        static let title = SwiftUI.Font.system(size: 22, weight: .regular)
        static let rowTitle = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 12, weight: .regular)
        static let button = SwiftUI.Font.system(size: 14, weight: .medium)
    }
}

// Legacy aliases used across views.
extension SwiftUI.Color {
    static let demarPrimary = Demar.Color.accent
    static let demarOnPrimary = Demar.Color.onAccent
    static let demarPrimaryContainer = Demar.Color.accentMuted
    static let demarOnPrimaryContainer = Demar.Color.onAccentMuted
    static let demarToggle = Demar.Color.toggle
    static let demarSecondary = Demar.Color.success
    static let demarOnSecondary = Demar.Color.onSuccess
    static let demarTertiary = Demar.Color.warning
    static let demarOnTertiary = Demar.Color.onWarning
    static let demarError = Demar.Color.danger
    static let demarOnError = Demar.Color.onDanger
    static let demarErrorContainer = Demar.Color.dangerMuted
    static let demarOnErrorContainer = Demar.Color.onDangerMuted
    static let demarSurface = Demar.Color.background
    static let demarOnSurface = Demar.Color.label
    static let demarSurfaceContainerHighest = Demar.Color.card
    static let demarOnSurfaceVariant = Demar.Color.secondaryLabel
    static let demarOutline = Demar.Color.separator
    static let demarOutlineVariant = Demar.Color.separator.opacity(0.55)
}

extension SwiftUI.Font {
    static let demarHeadlineMedium = Demar.Font.headline
    static let demarTitleLarge = Demar.Font.title
    static let demarTitleMedium = Demar.Font.rowTitle
    static let demarTitleMediumBold = Demar.Font.rowTitle
    static let demarBodyMedium = Demar.Font.body
    static let demarBodySmall = Demar.Font.caption
    static let demarLabelLarge = Demar.Font.button
}
