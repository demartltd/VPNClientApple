import SwiftUI

extension View {
    func demarScrollScreen() -> some View {
        scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color.demarSurface)
    }
}
