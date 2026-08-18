import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SupportChatPane: View {
    let session: AuthSession
    let ticketId: String?
    let themeId: String?
    let title: String
    var snackBar: SnackBarController
    var seedTicket: SupportTicket?
    var onTicketGone: () -> Void
    var onTicketCreated: (SupportTicket) -> Void = { _ in }

    @State private var ticket: SupportTicket?
    @State private var loading: Bool
    @State private var loadError: String?
    @State private var text = ""
    @State private var sending = false
    @State private var attaching = false
    @State private var pending: [SupportUploadMedia] = []
    @State private var editTarget: SupportMessage?
    @State private var menuMessage: SupportMessage?
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var composerFocused: Bool
    @State private var composerFocusID = 0

    init(
        session: AuthSession,
        ticketId: String?,
        themeId: String?,
        title: String,
        snackBar: SnackBarController,
        seedTicket: SupportTicket? = nil,
        onTicketGone: @escaping () -> Void,
        onTicketCreated: @escaping (SupportTicket) -> Void = { _ in }
    ) {
        self.session = session
        self.ticketId = ticketId
        self.themeId = themeId
        self.title = title
        self.snackBar = snackBar
        self.seedTicket = seedTicket
        self.onTicketGone = onTicketGone
        self.onTicketCreated = onTicketCreated
        let draft = ticketId == nil || ticketId?.isEmpty == true
        if let seedTicket {
            _ticket = State(initialValue: seedTicket)
            _loading = State(initialValue: false)
        } else if let ticketId, !ticketId.isEmpty,
                  let cached = SupportCacheStore.loadTicket(userId: session.userId, ticketId: ticketId)
        {
            _ticket = State(initialValue: cached)
            _loading = State(initialValue: false)
        } else {
            _ticket = State(initialValue: nil)
            _loading = State(initialValue: !draft)
        }
    }

    private var isDraft: Bool { ticketId == nil || ticketId?.isEmpty == true }
    private var activeTicketId: String? { ticket?.id ?? ticketId }
    private var remainingPhotoSlots: Int {
        max(0, SupportApi.maxMediaFiles - pending.count)
    }
    private var canWrite: Bool {
        if isDraft && ticket == nil { return true }
        guard let ticket else { return false }
        return ticket.isOpen && ticket.channel == SupportApi.channel
    }

    private var statusHint: String? {
        if ticket.map({ $0.isOpen && $0.channel != SupportApi.channel }) == true {
            return String(localized: "This ticket was opened in another source. Reply there or create a new ticket.")
        }
        if ticket.map({ !$0.isOpen }) == true {
            return String(localized: "This ticket is closed")
        }
        return nil
    }

    var body: some View {
        ZStack {
            Color.demarSurface
                #if os(iOS)
                .ignoresSafeArea(.container, edges: .bottom)
                #endif

            ZStack {
                messagesArea

                #if os(iOS)
                if let menuMessage {
                    SupportMessageMenuOverlay(
                        message: menuMessage,
                        session: session,
                        ticketId: activeTicketId ?? "",
                        canWrite: canWrite,
                        onCopy: {
                            if let t = menuMessage.text { PlatformServices.copyToPasteboard(t) }
                            self.menuMessage = nil
                        },
                        onEdit: {
                            editTarget = menuMessage
                            text = menuMessage.text ?? ""
                            self.menuMessage = nil
                        },
                        onDelete: {
                            let msg = menuMessage
                            self.menuMessage = nil
                            Task { await delete(msg) }
                        },
                        onDismiss: { self.menuMessage = nil }
                    )
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: menuMessage.id)
                    .zIndex(20)
                }
                #endif
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SupportComposerBar(
                text: $text,
                focused: $composerFocused,
                focusID: composerFocusID,
                editTarget: editTarget,
                sending: sending,
                attaching: attaching,
                pendingNames: canWrite && editTarget == nil ? pending.map { $0.fileName ?? "photo" } : [],
                enabled: canWrite,
                statusHint: statusHint,
                onCancelEdit: {
                    editTarget = nil
                    text = ""
                },
                onRemovePending: { i in
                    pending.remove(at: i)
                },
                onAttach: {
                    if remainingPhotoSlots <= 0 {
                        reportSendError(String(localized: "You can attach up to 10 photos"))
                        return
                    }
                    showPhotos = true
                },
                onSend: { Task { await send() } }
            )
            #if os(iOS)
            .padding(.bottom, 8)
            #else
            .padding(.bottom, 12)
            #endif
            .opacity(menuMessage == nil ? 1 : 0)
            .allowsHitTesting(menuMessage == nil)
            .contentShape(Rectangle())
        }
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .tabBar)
        .background {
            SupportDismissKeyboardOnPop {
                composerFocused = false
                composerFocusID += 1
            }
        }
        #endif
        .task(id: ticketId) {
            await warmAndRefresh()
        }
        .task(id: activeTicketId) {
            guard let id = activeTicketId, ticket?.isOpen == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await refresh(id: id, quiet: true)
            }
        }
        .photosPicker(
            isPresented: $showPhotos,
            selection: $photoItems,
            maxSelectionCount: max(1, remainingPhotoSlots),
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await ingestPhotos(items) }
        }
    }

    @ViewBuilder
    private var messagesArea: some View {
        if ticket == nil && !isDraft {
            if let loadError, !loading {
                ContentUnavailableView {
                    Label(String(localized: "Could not reach api. Try again"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(String(localized: "Retry")) {
                        Task { await warmAndRefresh(forceNetwork: true) }
                    }
                }
                .demarDetailNavigationTitle(title)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .demarDetailNavigationTitle(title)
            }
        } else if let ticket {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(ticket.messages) { msg in
                            SupportBubble(
                                message: msg,
                                session: session,
                                ticketId: ticket.id,
                                canWrite: canWrite,
                                selected: menuMessage?.id == msg.id,
                                onCopy: {
                                    if let t = msg.text { PlatformServices.copyToPasteboard(t) }
                                },
                                onEdit: {
                                    editTarget = msg
                                    text = msg.text ?? ""
                                },
                                onDelete: { Task { await delete(msg) } },
                                onOpenMenu: {
                                    #if os(iOS)
                                    let hasText = !msg.deleted && !(msg.text ?? "").isEmpty
                                    let canAct = !msg.deleted && canWrite && msg.isUser
                                    guard hasText || canAct else { return }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    menuMessage = msg
                                    #endif
                                }
                            )
                            .id(msg.id)
                            .frame(maxWidth: .infinity, alignment: msg.isUser ? .trailing : .leading)
                            .zIndex(menuMessage?.id == msg.id ? 1 : 0)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .demarDetailNavigationTitle(title)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: ticket.messages.count) { _, _ in
                    if let last = ticket.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = ticket.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        } else {
            Color.demarSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .demarDetailNavigationTitle(title)
        }
    }

    /// Seed / disk first; network is quiet when messages are already on screen.
    private func warmAndRefresh(forceNetwork: Bool = false) async {
        if isDraft {
            loading = false
            ticket = nil
            loadError = nil
            return
        }
        let id = ticketId!
        if !forceNetwork {
            if ticket == nil, let seedTicket {
                ticket = seedTicket
            }
            if ticket == nil,
               let cached = SupportCacheStore.loadTicket(userId: session.userId, ticketId: id)
            {
                ticket = cached
            }
            if ticket != nil {
                loading = false
                loadError = nil
                await refresh(id: id, quiet: true)
                return
            }
        }
        if ticket == nil { loading = true }
        loadError = nil
        await refresh(id: id, quiet: false)
        if ticket == nil { loading = false }
    }

    private func refresh(id: String, quiet: Bool) async {
        var delayMs = 250
        for attempt in 1...3 {
            do {
                let fresh = try await SupportApi.getTicket(
                    userId: session.userId,
                    loginAt: session.loginAt,
                    ticketId: id
                )
                ticket = fresh
                loadError = nil
                loading = false
                SupportCacheStore.saveTicket(userId: session.userId, ticket: fresh)
                _ = try? await SupportApi.markTicketRead(
                    userId: session.userId,
                    loginAt: session.loginAt,
                    ticketId: id
                )
                await SupportUnreadStore.shared.refresh(session: session)
                return
            } catch {
                if isSupportCancellation(error) {
                    // Keep seed/cache on screen; never paint cancel as a hard API failure.
                    if ticket != nil {
                        loading = false
                        return
                    }
                    if attempt < 3 {
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        delayMs *= 2
                        continue
                    }
                    loading = false
                    return
                }
                if let err = error as? DemarAPIError, err.isNotFound {
                    SupportCacheStore.removeTicket(userId: session.userId, ticketId: id)
                    onTicketGone()
                    return
                }
                if attempt < 3, isTransientSupportFailure(error) {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    delayMs *= 2
                    continue
                }
                let msg = supportErrorMessage(error)
                AppLog.shared.append("support getTicket #\(id): \(msg)")
                // Keep showing seeded/cached messages if we already have them.
                if ticket == nil {
                    loadError = msg
                    loading = false
                    if !quiet { snackBar.showError(msg) }
                } else if !quiet {
                    snackBar.showError(msg)
                }
                return
            }
        }
    }

    private func ingestPhotos(_ items: [PhotosPickerItem]) async {
        attaching = true
        defer {
            attaching = false
            photoItems = []
        }
        let room = remainingPhotoSlots
        guard room > 0 else {
            reportSendError(String(localized: "You can attach up to 10 photos"))
            return
        }
        let limited = Array(items.prefix(room))
        guard !limited.isEmpty else { return }
        do {
            let added = try await SupportAttachLoader.fromPhotos(limited)
            guard !added.isEmpty else { return }
            pending += added
        } catch {
            reportSendError(supportErrorMessage(error))
        }
    }

    private func delete(_ msg: SupportMessage) async {
        guard let id = activeTicketId else { return }
        do {
            let fresh = try await SupportApi.patchMessage(
                userId: session.userId,
                loginAt: session.loginAt,
                ticketId: id,
                messageId: msg.id,
                deleted: true
            )
            ticket = fresh
            SupportCacheStore.saveTicket(userId: session.userId, ticket: fresh)
        } catch {
            reportSendError(supportErrorMessage(error))
        }
    }

    private func send() async {
        guard canWrite else {
            reportSendError(String(localized: "This ticket is closed"))
            return
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = pending
        let editing = editTarget
        let creating = ticket == nil && isDraft

        if editing != nil {
            guard !body.isEmpty else { return }
        } else if creating {
            guard !body.isEmpty || !uploads.isEmpty else { return }
        } else if body.isEmpty && uploads.isEmpty {
            return
        }

        sending = true
        defer { sending = false }
        do {
            if let editing {
                guard let id = activeTicketId else { return }
                let fresh = try await SupportApi.patchMessage(
                    userId: session.userId,
                    loginAt: session.loginAt,
                    ticketId: id,
                    messageId: editing.id,
                    text: body
                )
                ticket = fresh
                SupportCacheStore.saveTicket(userId: session.userId, ticket: fresh)
                editTarget = nil
                text = ""
            } else if creating {
                guard let themeId else { return }
                let (deviceText, logFile) = await SupportApi.buildSilentDiagnostics()
                var created = try await SupportApi.postTicket(
                    userId: session.userId,
                    loginAt: session.loginAt,
                    text: body.isEmpty ? nil : body,
                    media: body.isEmpty ? uploads : [],
                    log: deviceText,
                    logMedia: [logFile],
                    themeId: themeId,
                    forceNew: true
                )
                text = ""
                if !body.isEmpty, !uploads.isEmpty {
                    created = try await SupportApi.postMediaSeparated(
                        userId: session.userId,
                        loginAt: session.loginAt,
                        media: uploads,
                        ticketId: created.id
                    )
                }
                ticket = created
                SupportCacheStore.saveTicket(userId: session.userId, ticket: created)
                onTicketCreated(created)
                pending = []
            } else {
                guard let id = activeTicketId else {
                    reportSendError(String(localized: "Could not reach api. Try again"))
                    return
                }
                var fresh = ticket
                if !body.isEmpty {
                    fresh = try await SupportApi.postTicket(
                        userId: session.userId,
                        loginAt: session.loginAt,
                        text: body,
                        ticketId: id
                    )
                    text = ""
                }
                if !uploads.isEmpty {
                    fresh = try await SupportApi.postMediaSeparated(
                        userId: session.userId,
                        loginAt: session.loginAt,
                        media: uploads,
                        ticketId: id
                    )
                    pending = []
                }
                if let fresh {
                    ticket = fresh
                    SupportCacheStore.saveTicket(userId: session.userId, ticket: fresh)
                }
                text = ""
                pending = []
            }
        } catch {
            let msg = supportErrorMessage(error)
            AppLog.shared.append("support send: \(msg)")
            reportSendError(msg)
        }
    }

    private func reportSendError(_ message: String) {
        snackBar.showError(message)
    }
}
