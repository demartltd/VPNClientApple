import SwiftUI

struct SupportScreen: View {
    let session: AuthSession
    var snackBar: SnackBarController

    /// Pushed on the *parent* Settings stack (no nested NavigationStack — that was dismissing Support).
    private enum Dest: Hashable, Identifiable {
        case chat(String)
        case draft(String)

        var id: String {
            switch self {
            case .chat(let id): "chat:\(id)"
            case .draft(let id): "draft:\(id)"
            }
        }
    }

    @State private var dest: Dest?
    @State private var tickets: [SupportTicketSummary] = []
    @State private var loadingList = true
    @State private var confirmNew = false
    @State private var pickTheme = false
    @State private var themes: [SupportTheme] = []
    @State private var selectedTheme: SupportTheme?

    var body: some View {
        listPane
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: startCreate) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                }
            }
            .navigationDestination(item: $dest) { dest in
                switch dest {
                case .chat(let id):
                    SupportChatPane(
                        session: session,
                        ticketId: id,
                        themeId: nil,
                        title: String(format: String(localized: "Ticket #%@"), id),
                        snackBar: snackBar,
                        seedTicket: SupportCacheStore.loadTicket(userId: session.userId, ticketId: id),
                        onTicketGone: { self.dest = nil }
                    )
                case .draft(let themeId):
                    SupportChatPane(
                        session: session,
                        ticketId: nil,
                        themeId: themeId,
                        title: String(localized: "Create ticket"),
                        snackBar: snackBar,
                        onTicketGone: { self.dest = nil },
                        onTicketCreated: { ticket in
                            SupportCacheStore.saveTicket(userId: session.userId, ticket: ticket)
                            Task { await reloadList(quiet: true) }
                            self.dest = .chat(ticket.id)
                        }
                    )
                }
            }
        .task(id: session.userId) {
            tickets = SupportCacheStore.loadList(userId: session.userId) ?? []
            SupportUnreadStore.shared.apply(tickets)
            if !tickets.isEmpty { loadingList = false }
            _ = await ensureThemes()
            await reloadList(quiet: !tickets.isEmpty)
            await SupportUnreadStore.shared.warmTickets(session: session, summaries: tickets)
        }
        .task(id: dest == nil) {
            guard dest == nil else { return }
            await reloadList(quiet: !tickets.isEmpty)
            while !Task.isCancelled, dest == nil {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, dest == nil else { return }
                await reloadList(quiet: true)
            }
        }
        .alert(String(localized: "Open ticket"), isPresented: $confirmNew) {
            Button(String(localized: "Create new")) {
                Task { await openThemePicker() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("You already have an open ticket. Create a new one?")
        }
        .tint(Color.white)
        .demarBottomSheet(isPresented: $pickTheme) { themeSheet }
    }

    @ViewBuilder
    private var listPane: some View {
        Group {
            if loadingList && tickets.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .demarDetailNavigationTitle(String(localized: "Support"))
            } else if tickets.isEmpty {
                ContentUnavailableView(
                    String(localized: "No tickets yet"),
                    systemImage: "bubble.left.and.bubble.right"
                )
                .demarDetailNavigationTitle(String(localized: "Support"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(tickets) { t in
                            let status = t.isOpen ? String(localized: "Open") : String(localized: "Closed")
                            let preview = t.preview?
                                .split(separator: "\n", omittingEmptySubsequences: false)
                                .first
                                .map(String.init)?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .nilIfBlank
                                ?? String(localized: "No messages")
                            SettingsActionButton(
                                systemImage: "person.wave.2",
                                title: "\(status) · #\(t.id)",
                                subtitle: preview,
                                unread: t.hasUnread,
                                action: { dest = .chat(t.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .demarDetailNavigationTitle(String(localized: "Support"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.demarSurface)
    }

    private var themeSheet: some View {
        VStack(spacing: 12) {
            if themes.isEmpty {
                Text("No topics available")
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Picker("", selection: $selectedTheme) {
                    ForEach(themes) { theme in
                        Text(theme.name).tag(Optional(theme))
                    }
                }
                #if os(iOS)
                .pickerStyle(.wheel)
                .frame(maxHeight: 140)
                #else
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif
            }

            Button {
                guard let selectedTheme else { return }
                pickTheme = false
                dest = .draft(selectedTheme.id)
            } label: {
                Text("Create ticket")
            }
            .buttonStyle(SupportPlainButtonStyle())
            .disabled(selectedTheme == nil)
            .opacity(selectedTheme == nil ? 0.45 : 1)
        }
        .demarSheetChrome(horizontalPadding: 16, bottomPadding: 8)
    }

    private func startCreate() {
        let openLocal = tickets.contains { $0.isOpen && $0.channel == SupportApi.channel }
        if openLocal { confirmNew = true }
        else { Task { await openThemePicker() } }
    }

    private func openThemePicker() async {
        guard await ensureThemes() else { return }
        selectedTheme = themes.count == 1 ? themes.first : (selectedTheme ?? themes.first)
        pickTheme = true
    }

    private func ensureThemes() async -> Bool {
        if !themes.isEmpty { return true }
        do {
            themes = try await SupportApi.listThemes(userId: session.userId, loginAt: session.loginAt)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func reloadList(quiet: Bool) async {
        if let cached = SupportCacheStore.loadList(userId: session.userId), tickets.isEmpty {
            tickets = cached
        }
        if tickets.isEmpty { loadingList = true }
        do {
            let fresh = try await SupportApi.listTickets(userId: session.userId, loginAt: session.loginAt)
            tickets = fresh
            SupportCacheStore.saveList(userId: session.userId, tickets: fresh)
            SupportUnreadStore.shared.apply(fresh)
        } catch {
            if tickets.isEmpty || !quiet { showError(error) }
        }
        loadingList = false
    }

    private func showError(_ error: Error) {
        if isSupportCancellation(error) { return }
        snackBar.showError(supportErrorMessage(error))
    }
}

// MARK: - Buttons

private struct SupportPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.demarTitleMedium.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.demarSurfaceContainerHighest)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
