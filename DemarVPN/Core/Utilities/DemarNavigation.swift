import SwiftUI

enum DemarSection: CaseIterable, Hashable, Identifiable {
    case home, servers, settings, account

    static let main: [DemarSection] = [.home, .servers, .settings]

    var id: Self { self }

    var title: String {
        switch self {
        case .home: String(localized: "Connect")
        case .servers: String(localized: "Servers")
        case .settings: String(localized: "Settings")
        case .account: String(localized: "Account")
        }
    }

    var sidebarIcon: String {
        switch self {
        case .home: "shield"
        case .servers: "globe"
        case .settings: "gearshape"
        case .account: "person.crop.circle"
        }
    }

    func tabIcon(selected: Bool) -> String {
        switch self {
        case .home: selected ? "shield.fill" : "shield"
        case .servers: "globe"
        case .settings: selected ? "gearshape.fill" : "gearshape"
        case .account: selected ? "person.crop.circle.fill" : "person.crop.circle"
        }
    }
}

extension View {
    #if os(macOS)
    func demarMacWindowTitle(_ section: DemarSection) -> some View {
        navigationTitle(section.title)
    }
    #endif

    /// iOS: title after scroll, no blur, soft top gradient. macOS: plain `navigationTitle` (as before).
    /// Apply on the `ScrollView` so scroll tracking works.
    func demarDetailNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
        modifier(DemarDetailNavTitle(title: title))
        #else
        navigationTitle(title)
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

#if os(iOS)
private struct DemarDetailNavTitle: ViewModifier {
    let title: String
    @State private var showTitle = false

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color.demarSurface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .opacity(showTitle ? 1 : 0)
                        .animation(.easeInOut(duration: 0.18), value: showTitle)
                }
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.10), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 88)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, y in
                let show = y > 16
                guard showTitle != show else { return }
                showTitle = show
            }
    }
}
#endif
