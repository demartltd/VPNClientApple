import SwiftUI

enum DemarSection: CaseIterable, Hashable, Identifiable {
    case home, servers, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Подключение"
        case .servers: "Сервера"
        case .settings: "Настройки"
        }
    }

    var sidebarIcon: String {
        switch self {
        case .home: "shield"
        case .servers: "globe"
        case .settings: "gearshape"
        }
    }

    func tabIcon(selected: Bool) -> String {
        switch self {
        case .home: selected ? "shield.fill" : "shield"
        case .servers: "globe"
        case .settings: selected ? "gearshape.fill" : "gearshape"
        }
    }
}

extension View {
    #if os(macOS)
    func demarMacWindowTitle(_ section: DemarSection) -> some View {
        navigationTitle(section.title)
    }
    #endif

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
