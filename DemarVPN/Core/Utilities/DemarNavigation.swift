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

    #if os(iOS)
    /// Корень `NavigationStack`: подпись для кнопки «назад» и long-press history menu (bar скрыт — hero в ScrollView).
    func demarNavigationRoot(backHistoryLabel: String) -> some View {
        navigationTitle(backHistoryLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
    }
    #endif
}
