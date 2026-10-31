import Foundation

struct SupportTicketSummary: Equatable, Identifiable, Sendable {
    let id: String
    let status: String
    let openedAt: String?
    let closedAt: String?
    let channel: String?
    let sourceId: String?
    let themeId: String?
    let preview: String?
    let lastMessageRole: String?
    let hasUnread: Bool

    var isOpen: Bool { status == "open" }

    func markingRead() -> SupportTicketSummary {
        guard hasUnread else { return self }
        return SupportTicketSummary(
            id: id, status: status, openedAt: openedAt, closedAt: closedAt,
            channel: channel, sourceId: sourceId, themeId: themeId,
            preview: preview, lastMessageRole: lastMessageRole, hasUnread: false
        )
    }
}

struct SupportTheme: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct SupportMedia: Equatable, Sendable {
    let type: String?
    let url: String?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int64?
    let width: Int?
    let height: Int?

    var isPhoto: Bool {
        if type == "photo" { return true }
        if mimeType?.hasPrefix("image/") == true { return true }
        let name = (fileName ?? "").lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic"].contains { name.hasSuffix($0) }
    }
}

struct SupportResolved: Equatable, Sendable {
    let text: String?
    let media: [SupportMedia]
}

struct SupportMessage: Equatable, Identifiable, Sendable {
    let id: String
    let role: String
    let edited: Bool
    let deleted: Bool
    let createdAt: String?
    let resolved: SupportResolved?

    var isUser: Bool { role == "user" }
    var text: String? { resolved?.text?.nilIfBlank }
    var media: [SupportMedia] { resolved?.media ?? [] }
}

struct SupportTicket: Equatable, Identifiable, Sendable {
    let id: String
    let status: String
    let channel: String?
    let sourceId: String?
    let themeId: String?
    let openedAt: String?
    let closedAt: String?
    let messages: [SupportMessage]

    var isOpen: Bool { status == "open" }
}

struct SupportUploadMedia: Equatable, Sendable {
    let dataBase64: String
    let fileName: String?
    let mimeType: String?
}

enum SupportApi {
    static var baseURL: URL { DemarEnv.supportAPIBase }
    static let vpnSourceId = "2"
    static let maxMediaBytes = 25 * 1024 * 1024
    static let maxMediaFiles = 10

    static var channel: String { AppPlatform.supportChannel }

    static func listTickets(userId: String, loginAt: String) async throws -> [SupportTicketSummary] {
        let json = try await get("/support/me", userId: userId, loginAt: loginAt)
        return parseSummaries(json["tickets"] as? [[String: Any]])
    }

    static func listThemes(userId: String, loginAt: String, sourceId: String = vpnSourceId) async throws -> [SupportTheme] {
        let json = try await get("/support/themes", userId: userId, loginAt: loginAt, extra: ["sourceId": sourceId])
        return parseThemes(json["themes"] as? [[String: Any]])
    }

    static func getTicket(userId: String, loginAt: String, ticketId: String) async throws -> SupportTicket {
        let json = try await get("/support/tickets/\(enc(ticketId))", userId: userId, loginAt: loginAt)
        if let o = json["ticket"] as? [String: Any] {
            return parseTicket(o)
        }
        // Some responses return the ticket object at the root.
        if json["id"] != nil || json["_id"] != nil || json["messages"] != nil {
            return parseTicket(json)
        }
        throw DemarAPIError(message: "missing ticket", statusCode: 500, retryAfterSeconds: nil, hint: nil)
    }

    static func markTicketRead(userId: String, loginAt: String, ticketId: String) async throws -> SupportTicket {
        let json = try await DemarHttp.postJSON(
            url("support/tickets/\(enc(ticketId))/read"),
            body: DemarHttp.sessionBody(userId: userId, loginAt: loginAt)
        )
        guard let o = json["ticket"] as? [String: Any] else {
            throw DemarAPIError(message: "missing ticket", statusCode: 500, retryAfterSeconds: nil, hint: nil)
        }
        return parseTicket(o)
    }

    static func postTicket(
        userId: String,
        loginAt: String,
        text: String? = nil,
        media: [SupportUploadMedia] = [],
        log: String? = nil,
        logMedia: [SupportUploadMedia] = [],
        themeId: String? = nil,
        sourceId: String? = vpnSourceId,
        ticketId: String? = nil,
        forceNew: Bool = false
    ) async throws -> SupportTicket {
        var body = DemarHttp.sessionBody(userId: userId, loginAt: loginAt)
        body["channel"] = channel
        if forceNew { body["forceNew"] = true }
        if let ticketId, !ticketId.isEmpty { body["ticketId"] = ticketId }
        if let text, !text.isEmpty { body["text"] = text }
        putLog(&body, log: log, logMedia: logMedia)
        if let themeId, !themeId.isEmpty { body["themeId"] = themeId }
        if let sourceId, !sourceId.isEmpty { body["sourceId"] = sourceId }
        if !media.isEmpty { body["media"] = mediaToJSON(media) }
        let hasMedia = !media.isEmpty || !logMedia.isEmpty
        let json = try await DemarHttp.postJSON(url("support/tickets"), body: body, media: hasMedia)
        guard let o = json["ticket"] as? [String: Any] else {
            throw DemarAPIError(message: "missing ticket", statusCode: 500, retryAfterSeconds: nil, hint: nil)
        }
        return parseTicket(o)
    }

    /// Create ticket with silent diagnostics: device text + full journal.txt attach.
    static func postTicketCreate(
        userId: String,
        loginAt: String,
        text: String? = nil,
        log: String? = nil,
        logMedia: [SupportUploadMedia] = [],
        themeId: String? = nil,
        forceNew: Bool = false
    ) async throws -> SupportTicket {
        try await postTicketWithRetry(
            userId: userId, loginAt: loginAt, text: text, media: [],
            log: log, logMedia: logMedia, themeId: themeId, ticketId: nil, forceNew: forceNew, maxAttempts: 2
        )
    }

    private static func postTicketWithRetry(
        userId: String,
        loginAt: String,
        text: String?,
        media: [SupportUploadMedia],
        log: String?,
        logMedia: [SupportUploadMedia],
        themeId: String?,
        ticketId: String?,
        forceNew: Bool,
        maxAttempts: Int = 3
    ) async throws -> SupportTicket {
        var delayMs = 400
        var lastError: Error = DemarAPIError(message: "ticket post failed", statusCode: 500, retryAfterSeconds: nil, hint: nil)
        for attempt in 1...maxAttempts {
            do {
                return try await postTicket(
                    userId: userId, loginAt: loginAt, text: text, media: media,
                    log: log, logMedia: logMedia, themeId: themeId, ticketId: ticketId, forceNew: forceNew
                )
            } catch {
                lastError = error
                let msg = (error as? DemarAPIError)?.message ?? error.localizedDescription
                await MainActor.run {
                    AppLog.shared.append("support ticket post try\(attempt): \(msg)")
                }
                let retryable =
                    msg.localizedCaseInsensitiveContains("fetch failed")
                    || msg.localizedCaseInsensitiveContains("архив")
                    || msg.localizedCaseInsensitiveContains("archive")
                    || (error as? DemarAPIError)?.statusCode == 502
                guard attempt < maxAttempts, retryable else { throw error }
                try? await Task.sleep(for: .milliseconds(delayMs))
                delayMs *= 2
            }
        }
        throw lastError
    }

    /// Album: one POST with media[1…10] → one ticket message.
    static func postMediaAlbum(
        userId: String,
        loginAt: String,
        media: [SupportUploadMedia],
        ticketId: String
    ) async throws -> SupportTicket {
        precondition(!media.isEmpty)
        await MainActor.run {
            AppLog.shared.append("support media album: \(media.count) files")
        }
        return try await postTicketWithRetry(
            userId: userId,
            loginAt: loginAt,
            text: nil,
            media: media,
            log: nil,
            logMedia: [],
            themeId: nil,
            ticketId: ticketId,
            forceNew: false,
            maxAttempts: 2
        )
    }

    static func patchMessage(
        userId: String,
        loginAt: String,
        ticketId: String,
        messageId: String,
        text: String? = nil,
        deleted: Bool = false
    ) async throws -> SupportTicket {
        var body = DemarHttp.sessionBody(userId: userId, loginAt: loginAt)
        body["channel"] = channel
        if deleted {
            body["deleted"] = true
        } else if let text {
            body["text"] = text
        } else {
            throw DemarAPIError(message: "text or deleted required", statusCode: 400, retryAfterSeconds: nil, hint: nil)
        }
        let json = try await DemarHttp.patchJSON(
            url("support/tickets/\(enc(ticketId))/messages/\(enc(messageId))"),
            body: body
        )
        guard let o = json["ticket"] as? [String: Any] else {
            throw DemarAPIError(message: "missing ticket", statusCode: 500, retryAfterSeconds: nil, hint: nil)
        }
        return parseTicket(o)
    }

    static func uploadFromData(_ data: Data, fileName: String, mimeType: String?) throws -> SupportUploadMedia {
        if data.isEmpty {
            throw DemarAPIError(message: "empty media", statusCode: 400, retryAfterSeconds: nil, hint: nil)
        }
        if data.count > maxMediaBytes {
            throw DemarAPIError(message: "media_too_large", statusCode: 413, retryAfterSeconds: nil, hint: nil)
        }
        return SupportUploadMedia(
            dataBase64: data.base64EncodedString(),
            fileName: fileName,
            mimeType: mimeType ?? Self.mimeType(for: fileName) ?? "application/octet-stream"
        )
    }

    struct SilentDiagnostics {
        let logText: String
        let logMedia: [SupportUploadMedia]
    }

    /// Device summary as log text; full journal as `journal.txt` attach.
    static func buildSilentDiagnostics() async -> SilentDiagnostics {
        let device = await DeviceIdentity.load()
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let latestLabel: String
        if let latest = try? await withTimeout(seconds: 3, { try await AppVersionApi.fetchLatest() }) {
            latestLabel = "\(latest.version)#\(latest.buildNumber)"
        } else {
            latestLabel = "—"
        }
        var deviceText = "Demar VPN \(ver) (\(build))\nLatest: \(latestLabel)\nUA: \(DemarHttp.userAgent)\n--- device ---\n"
        for row in device {
            deviceText += "\(row.label)=\(row.value)\n"
        }
        deviceText = String(deviceText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        let journal = await MainActor.run {
            let body = AppLog.shared.joinedText
            return body.isEmpty ? "(empty)" : body
        }
        let journalData = Data(journal.utf8)
        let file = SupportUploadMedia(
            dataBase64: journalData.base64EncodedString(),
            fileName: "journal.txt",
            mimeType: "text/plain"
        )
        return SilentDiagnostics(logText: deviceText, logMedia: [file])
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    static func loadMediaBytes(
        userId: String,
        loginAt: String,
        mediaPath: String,
        ticketId: String?
    ) async throws -> Data {
        var path = mediaPath
        if path.hasPrefix(baseURL.absoluteString) {
            path = String(path.dropFirst(baseURL.absoluteString.count))
        }
        if path.hasPrefix("http"), let u = URL(string: path) {
            path = u.path + (u.query.map { "?\($0)" } ?? "")
        }
        if !path.hasPrefix("/") { path = "/\(path)" }
        if path.hasPrefix("/api/telegram-media?") {
            path = "/support/media?" + path.dropFirst("/api/telegram-media?".count)
        }
        let cacheKey = "\(path)|\(ticketId ?? "")|\(userId)"
        if let cached = SupportMediaCache.load(cacheKey) { return cached }
        let resolvedPath = path
        return try await KeyedFlight.run("media:\(cacheKey)") {
            if let cached = SupportMediaCache.load(cacheKey) { return cached }
            let sep = resolvedPath.contains("?") ? "&" : "?"
            let ticketQ = ticketId.flatMap { $0.isEmpty ? nil : "&ticketId=\(Self.enc($0))" } ?? ""
            let full = "\(Self.baseURL.absoluteString)\(resolvedPath)\(sep)userId=\(Self.enc(userId))&loginAt=\(Self.enc(loginAt))\(ticketQ)"
            guard let url = URL(string: full) else {
                throw DemarAPIError(message: "bad media url", statusCode: 400, retryAfterSeconds: nil, hint: nil)
            }
            let data = try await DemarHttp.getData(url)
            SupportMediaCache.save(cacheKey, data)
            return data
        }
    }

    // MARK: - Cache encode/decode

    static func encodeSummaries(_ list: [SupportTicketSummary]) -> String {
        let arr: [[String: Any]] = list.map {
            var o: [String: Any] = ["id": $0.id, "status": $0.status, "hasUnread": $0.hasUnread]
            putOpt(&o, "openedAt", $0.openedAt)
            putOpt(&o, "closedAt", $0.closedAt)
            putOpt(&o, "channel", $0.channel)
            putOpt(&o, "sourceId", $0.sourceId)
            putOpt(&o, "themeId", $0.themeId)
            putOpt(&o, "preview", $0.preview)
            putOpt(&o, "lastMessageRole", $0.lastMessageRole)
            return o
        }
        return jsonString(arr)
    }

    static func decodeSummaries(_ raw: String) -> [SupportTicketSummary]? {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return parseSummaries(arr)
    }

    static func encodeTicket(_ ticket: SupportTicket) -> String {
        var o: [String: Any] = [
            "id": ticket.id,
            "status": ticket.status,
            "messages": ticket.messages.map(encodeMessage),
        ]
        putOpt(&o, "channel", ticket.channel)
        putOpt(&o, "sourceId", ticket.sourceId)
        putOpt(&o, "themeId", ticket.themeId)
        putOpt(&o, "openedAt", ticket.openedAt)
        putOpt(&o, "closedAt", ticket.closedAt)
        return jsonString(o)
    }

    static func decodeTicket(_ raw: String) -> SupportTicket? {
        guard let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseTicket(o)
    }

    // MARK: - Private

    private static func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + "/" + path)!
    }

    private static func enc(_ v: String) -> String {
        v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? v
    }

    private static func get(
        _ path: String,
        userId: String,
        loginAt: String,
        extra: [String: String] = [:]
    ) async throws -> [String: Any] {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var comp = URLComponents(string: baseURL.absoluteString + "/" + clean)!
        var items = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "loginAt", value: loginAt),
        ]
        items += extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        comp.queryItems = items
        guard let url = comp.url else {
            throw DemarAPIError(message: "bad url", statusCode: 400, retryAfterSeconds: nil, hint: nil)
        }
        return try await DemarHttp.getJSON(url)
    }

    private static func mediaToJSON(_ media: [SupportUploadMedia]) -> [[String: Any]] {
        media.map { m in
            var item: [String: Any] = ["data": m.dataBase64]
            if let n = m.fileName { item["fileName"] = n }
            if let t = m.mimeType { item["mimeType"] = t }
            return item
        }
    }

    private static func putLog(_ body: inout [String: Any], log: String?, logMedia: [SupportUploadMedia]) {
        let text = log?.nilIfBlank
        if logMedia.isEmpty {
            if let text { body["log"] = text }
            return
        }
        var obj: [String: Any] = ["media": mediaToJSON(logMedia)]
        if let text { obj["text"] = text }
        body["log"] = obj
    }

    private static func putOpt(_ o: inout [String: Any], _ key: String, _ value: String?) {
        if let value { o[key] = value }
    }

    private static func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    private static func encodeMessage(_ m: SupportMessage) -> [String: Any] {
        var o: [String: Any] = [
            "id": m.id,
            "role": m.role,
            "edited": m.edited,
            "deleted": m.deleted,
        ]
        putOpt(&o, "createdAt", m.createdAt)
        if let r = m.resolved {
            var resolved: [String: Any] = [
                "media": r.media.map { med -> [String: Any] in
                    var item: [String: Any] = [:]
                    putOpt(&item, "type", med.type)
                    putOpt(&item, "url", med.url)
                    putOpt(&item, "fileName", med.fileName)
                    putOpt(&item, "mimeType", med.mimeType)
                    if let s = med.fileSize { item["fileSize"] = s }
                    if let w = med.width { item["width"] = w }
                    if let h = med.height { item["height"] = h }
                    return item
                },
            ]
            putOpt(&resolved, "text", r.text)
            o["resolved"] = resolved
        }
        return o
    }

    private static func parseSummaries(_ arr: [[String: Any]]?) -> [SupportTicketSummary] {
        (arr ?? []).compactMap { o in
            guard let id = anyId(o["id"]) ?? anyId(o["_id"]) else { return nil }
            return SupportTicketSummary(
                id: id,
                status: (o["status"] as? String) ?? "",
                openedAt: str(o["openedAt"]),
                closedAt: str(o["closedAt"]),
                channel: str(o["channel"]),
                sourceId: str(o["sourceId"]),
                themeId: str(o["themeId"]),
                preview: str(o["preview"]),
                lastMessageRole: str(o["lastMessageRole"]),
                hasUnread: bool(o["hasUnread"])
            )
        }
    }

    private static func parseThemes(_ arr: [[String: Any]]?) -> [SupportTheme] {
        (arr ?? []).compactMap { o in
            guard let id = anyId(o["id"]) ?? anyId(o["_id"]) else { return nil }
            let name = (o["name"] as? String)?.nilIfBlank ?? id
            return SupportTheme(id: id, name: name)
        }
    }

    private static func parseTicket(_ o: [String: Any]) -> SupportTicket {
        let msgs = (o["messages"] as? [[String: Any]] ?? []).map(parseMessage)
        return SupportTicket(
            id: anyId(o["id"]) ?? anyId(o["_id"]) ?? "",
            status: (o["status"] as? String) ?? "",
            channel: str(o["channel"]),
            sourceId: str(o["sourceId"]),
            themeId: str(o["themeId"]),
            openedAt: str(o["openedAt"]),
            closedAt: str(o["closedAt"]),
            messages: msgs
        )
    }

    private static func parseMessage(_ o: [String: Any]) -> SupportMessage {
        let resolved: SupportResolved? = {
            guard let r = o["resolved"] as? [String: Any] else { return nil }
            let media = (r["media"] as? [[String: Any]] ?? []).map { m in
                SupportMedia(
                    type: str(m["type"]),
                    url: str(m["url"]),
                    fileName: str(m["fileName"]),
                    mimeType: str(m["mimeType"]),
                    fileSize: int64(m["fileSize"]),
                    width: int(m["width"]),
                    height: int(m["height"])
                )
            }
            return SupportResolved(text: str(r["text"]), media: media)
        }()
        return SupportMessage(
            id: anyId(o["id"]) ?? "",
            role: (o["role"] as? String) ?? "",
            edited: bool(o["edited"]),
            deleted: bool(o["deleted"]),
            createdAt: str(o["createdAt"]),
            resolved: resolved
        )
    }

    /// API may send ids as string or number (Android `optString` coerces both).
    private static func anyId(_ v: Any?) -> String? {
        if let s = v as? String { return s.nilIfBlank }
        if let n = v as? NSNumber { return n.stringValue.nilIfBlank }
        if let i = v as? Int { return String(i) }
        if let i = v as? Int64 { return String(i) }
        return nil
    }

    private static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || t == "null") ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue.nilIfBlank }
        return nil
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int, i > 0 { return i }
        if let n = v as? NSNumber, n.intValue > 0 { return n.intValue }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let i = v as? Int64, i > 0 { return i }
        if let i = v as? Int, i > 0 { return Int64(i) }
        if let n = v as? NSNumber, n.int64Value > 0 { return n.int64Value }
        return nil
    }

    private static func mimeType(for fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return nil
        }
    }
}
