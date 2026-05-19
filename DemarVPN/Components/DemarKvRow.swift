import SwiftUI

struct DemarKvRow: View {
    let key: String
    let value: String
    var keyWidth: CGFloat = 88

    var body: some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.demarBodySmall)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .frame(width: keyWidth, alignment: .leading)
            Text(value)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurface)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
