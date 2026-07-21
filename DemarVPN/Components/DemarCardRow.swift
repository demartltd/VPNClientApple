import SwiftUI

/// Opaque top mask so scroll content does not show under the status bar / Dynamic Island.
struct DemarTopScrollCurtain: View {
    var body: some View {
        Color.demarSurface
            .frame(maxWidth: .infinity)
            .frame(height: 0)
            .background(Color.demarSurface.ignoresSafeArea(edges: .top))
            .allowsHitTesting(false)
    }
}

extension View {
    func demarScrollScreen() -> some View {
        scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color.demarSurface)
            .overlay(alignment: .top) { DemarTopScrollCurtain() }
    }
}
