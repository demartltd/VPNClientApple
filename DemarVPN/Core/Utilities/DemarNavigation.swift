import SwiftUI

enum DemarURLScheme {
    static let name = "demarvpn"

    /// Path segments for `demarvpn://host/path` (host becomes first segment; `auth` excluded).
    static func pathComponents(from url: URL) -> [String] {
        var parts = [String]()
        if url.scheme == name,
           let host = url.host(percentEncoded: false)?.nilIfBlank,
           host != "auth"
        {
            parts.append(host)
        }
        parts.append(contentsOf: url.pathComponents.filter { $0 != "/" })
        if parts.first == "open" { parts.removeFirst() }
        return parts
    }
}

/// All in-app deeplinks except `demarvpn://auth?...` (handled separately for OAuth).
enum DemarDeepLink: Equatable {
    enum AccountSheet: Equatable {
        case traffic, buy, plans
    }

    case account(AccountSheet)
    case payReturn(success: Bool)
    case settings(SettingsRoute)

    init?(url: URL) {
        let parts = DemarURLScheme.pathComponents(from: url)
        if let sheet = Self.accountSheet(parts) {
            self = .account(sheet)
            return
        }
        switch parts {
        case ["pay", "ok"]:
            self = .payReturn(success: true)
        case ["pay", "fail"]:
            self = .payReturn(success: false)
        default:
            guard let route = SettingsRoute(pathComponents: parts) else { return nil }
            self = .settings(route)
        }
    }

    private static func accountSheet(_ parts: [String]) -> AccountSheet? {
        switch parts {
        case ["account", "buy"]: return .buy
        case ["account", "plans"]: return .plans
        case ["account", "traffic"], ["settings", "traffic"]: return .traffic
        default: return nil
        }
    }
}

enum SupportRoute: Hashable, Identifiable {
    case chat(String)
    case draft(String)

    var id: String { pathComponent }

    var pathComponent: String {
        switch self {
        case .chat(let id): "settings/support/ticket/\(id)"
        case .draft(let themeId): "settings/support/new/\(themeId)"
        }
    }
}

enum ServiceRoute: Hashable, Identifiable {
    case customProbes

    var id: String { pathComponent }
    var pathComponent: String { "settings/service/custom-checks" }
}

enum SettingsRoute: Hashable, Identifiable {
    case appSettings
    case serviceMenu(ServiceRoute? = nil)
    case support(SupportRoute? = nil)
    case document(LegalDocument)

    var id: String { pathComponent }

    var pathComponent: String {
        switch self {
        case .appSettings:
            "settings/app"
        case .serviceMenu(let route):
            route?.pathComponent ?? "settings/service"
        case .support(let route):
            route?.pathComponent ?? "settings/support"
        case .document(let document):
            "settings/documents/\(document.rawValue)"
        }
    }

    init?(url: URL) {
        self.init(pathComponents: DemarURLScheme.pathComponents(from: url))
    }

    init?(pathComponents: [String]) {
        switch pathComponents {
        case ["settings", "app"]:
            self = .appSettings
        case ["settings", "service"]:
            self = .serviceMenu()
        case ["settings", "service", "custom-checks"]:
            self = .serviceMenu(.customProbes)
        case ["settings", "support"]:
            self = .support()
        case let parts where parts.count == 4 && parts[0] == "settings" && parts[1] == "support" && parts[2] == "ticket":
            guard !parts[3].isEmpty else { return nil }
            self = .support(.chat(parts[3]))
        case let parts where parts.count == 4 && parts[0] == "settings" && parts[1] == "support" && parts[2] == "new":
            guard !parts[3].isEmpty else { return nil }
            self = .support(.draft(parts[3]))
        case let parts where parts.count == 3 && parts[0] == "settings" && parts[1] == "documents":
            guard let document = LegalDocument(rawValue: parts[2]) else { return nil }
            self = .document(document)
        default:
            return nil
        }
    }
}

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

    #if os(iOS)
    /// iOS 26+: icon-only floating tab (Liquid Glass). Earlier: visible title — no floating chrome.
    @ViewBuilder
    func accountTabLabel(selected: Bool) -> some View {
        if #available(iOS 26.0, *) {
            Image(systemName: tabIcon(selected: selected))
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: tabIcon(selected: selected))
        }
    }
    #endif
}

extension View {
    func demarPush<Item: Hashable, Content: View>(
        _ item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Content
    ) -> some View {
        navigationDestination(item: item, destination: destination)
    }

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
