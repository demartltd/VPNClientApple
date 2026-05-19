import SwiftUI

extension View {
    @ViewBuilder
    func demarInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
