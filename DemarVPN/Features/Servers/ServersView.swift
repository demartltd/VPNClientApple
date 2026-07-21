import SwiftUI

struct ServersView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController
    @State private var selectedProtocol: ServerProtocol = .hysteria2
    @State private var selectedTier: ServerTier?
    @State private var pullArmed = false

    private let refreshPullThreshold: CGFloat = 16

    var body: some View {
        Group {
            if isActive { content } else { Color.clear }
        }
        .task(id: isActive) {
            guard isActive else { return }
            selectedProtocol = appState.selectedServer?.serverProtocol ?? .hysteria2
        }
        .onChange(of: appState.selectedServer?.id) { _, _ in
            selectedProtocol = appState.selectedServer?.serverProtocol ?? selectedProtocol
        }
    }

    private var filteredServers: [ServerProfile] {
        appState.servers.filterServers(protocol: selectedProtocol, tier: selectedTier)
    }

    private var tierOptions: [SegmentOption] {
        [SegmentOption(id: "all", title: "All")]
            + appState.servers.visibleTiers().map { SegmentOption(id: $0.rawValue, title: $0.title) }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SegmentBar(
                options: ServerProtocol.allCases.map { SegmentOption(id: $0.rawValue, title: $0.rawValue) },
                selectedID: selectedProtocol.rawValue,
                font: .demarTitleMediumBold
            ) { id in
                if let proto = ServerProtocol(rawValue: id) { selectedProtocol = proto }
            }
            SegmentBar(
                options: tierOptions,
                selectedID: selectedTier?.rawValue ?? "all",
                font: .demarLabelLarge
            ) { id in
                selectedTier = id == "all" ? nil : ServerTier(rawValue: id)
            }
            Divider()
                .overlay(Color.demarOutline.opacity(0.25))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredServers) { server in
                        ServerRow(
                            profile: server,
                            selected: appState.selectedServer?.id == server.id
                        ) {
                            Task {
                                await appState.switchServer(to: server)
                                snackBar.showSuccess("Сервер выбран")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(.none, value: filteredServers.map(\.id))
            }
            .contentMargins(0)
            .scrollBounceBehavior(.always)
            .demarScrollPullDistance { handlePull($0) }
            .demarScrollScreen()
        }
        .background(Color.demarSurface)
    }

    private func handlePull(_ pull: CGFloat) {
        if pull < 8 {
            if !appState.isRefreshingServers { pullArmed = false }
            return
        }
        guard !appState.isRefreshingServers, !pullArmed else { return }
        guard pull >= refreshPullThreshold else { return }
        guard appState.beginServersRefresh() else { return }
        pullArmed = true
        PlatformServices.lightImpact()
        AppLog.shared.append("[ui] servers pull-to-refresh")
        Task {
            let ok = await appState.endServersRefresh(minimumVisibleDuration: .seconds(4))
            if ok { snackBar.showSuccess("Серверы обновлены") }
        }
    }
}

private struct SegmentOption: Identifiable, Hashable {
    let id: String
    let title: String
}

private struct SegmentBar: View {
    let options: [SegmentOption]
    let selectedID: String
    let font: Font
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(options) { option in
                    let isSelected = option.id == selectedID
                    Text(option.title)
                        .font(font)
                        .foregroundStyle(isSelected ? Color.demarOnSurface : Color.demarOnSurfaceVariant)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isSelected ? Color.demarPrimary.opacity(0.18) : Color.clear)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        select(at: value.location.x, width: geo.size.width)
                    }
            )
        }
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.demarSurfaceContainerHighest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.demarOutline.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transaction { $0.disablesAnimations = true }
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard width > 0, !options.isEmpty else { return }
        let index = min(max(Int((x / width) * CGFloat(options.count)), 0), options.count - 1)
        let id = options[index].id
        guard id != selectedID else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { onSelect(id) }
        PlatformServices.lightImpact()
    }
}

private struct ServerRow: View {
    let profile: ServerProfile
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CountryFlag(profile: profile)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.listTitle)
                        .font(.demarTitleMediumBold)
                        .foregroundStyle(selected ? Color.demarOnPrimaryContainer : Color.demarOnSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !profile.listSubtitle.isEmpty {
                        Text(profile.listSubtitle)
                            .font(.demarBodySmall)
                            .foregroundStyle(
                                selected
                                    ? Color.demarOnPrimaryContainer.opacity(0.75)
                                    : Color.demarOnSurfaceVariant
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(selected ? Color.demarPrimaryContainer : Color.demarSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.demarPrimary.opacity(0.35) : Color.demarOutline.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .transaction { $0.disablesAnimations = true }
    }
}

private struct CountryFlag: View {
    let profile: ServerProfile

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.demarPrimary.opacity(0.1))
            if profile.flagEmoji.isEmpty {
                Text(profile.countryCode ?? "?")
                    .font(.demarBodySmall.weight(.bold))
                    .foregroundStyle(Color.demarPrimary)
            } else {
                Text(profile.flagEmoji)
                    .font(.system(size: 22))
            }
        }
        .frame(width: 36, height: 36)
    }
}

private extension View {
    @ViewBuilder
    func demarScrollPullDistance(_ onPull: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, -geo.contentOffset.y)
            } action: { _, pull in
                onPull(pull)
            }
        } else {
            self
        }
    }
}
