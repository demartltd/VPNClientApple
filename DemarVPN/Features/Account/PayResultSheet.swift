import SwiftUI

struct PayResultSheet: View {
    let success: Bool
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(success ? Color.demarPrimary : Color.demarError)
                .accessibilityHidden(true)

            Text(
                success
                    ? String(localized: "Payment successful. Refresh the server list.")
                    : String(localized: "Payment failed")
            )
            .font(.demarTitleMedium)
            .foregroundStyle(Color.demarOnSurface)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            Button(action: onDismiss) {
                Text(String(localized: "OK"))
                    .font(.demarTitleMedium)
                    .foregroundStyle(Color.demarOnPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.demarPrimary)
                    )
            }
            .buttonStyle(.plain)
        }
        .demarSheetChrome(bottomPadding: 8)
    }
}
