import Foundation
import Observation

@MainActor
@Observable
final class SupportUnreadStore {
    static let shared = SupportUnreadStore()

    var hasUnread = false

    func clear() { hasUnread = false }

    func apply(_ tickets: [SupportTicketSummary]) {
        hasUnread = tickets.contains(where: \.hasUnread)
    }

    /// Clear unread flag for one ticket in disk list + badge (no network).
    func noteRead(ticketId: String, userId: String) {
        guard let list = SupportCacheStore.loadList(userId: userId) else { return }
        let updated = list.map { $0.id == ticketId ? $0.markingRead() : $0 }
        SupportCacheStore.saveList(userId: userId, tickets: updated)
        apply(updated)
    }

    /// Called on app start / sign-in — same moment as servers & account (Android parity + ticket warm).
    func refresh(session: AuthSession, warm: Bool = true) async {
        await Flight.run("support.unread") {
            do {
                let tickets = try await SupportApi.listTickets(userId: session.userId, loginAt: session.loginAt)
                self.apply(tickets)
                SupportCacheStore.saveList(userId: session.userId, tickets: tickets)
                if warm { await self.warmTickets(session: session, summaries: tickets) }
            } catch {
                // Quiet — badge stays until next successful fetch.
            }
        }
    }

    /// Prefetch full tickets missing from disk so the first chat open is cache-hit.
    func warmTickets(session: AuthSession, summaries: [SupportTicketSummary]) async {
        let missing = summaries.filter {
            SupportCacheStore.loadTicket(userId: session.userId, ticketId: $0.id) == nil
        }
        guard !missing.isEmpty else { return }
        await Flight.forEachLimited(missing) { summary in
            guard let fresh = try? await SupportApi.getTicket(
                userId: session.userId,
                loginAt: session.loginAt,
                ticketId: summary.id
            ) else { return }
            SupportCacheStore.saveTicket(userId: session.userId, ticket: fresh)
        }
    }
}

enum SupportCacheStore {
    private static let dirName = "support_cache"

    static func loadList(userId: String) -> [SupportTicketSummary]? {
        read(userId: userId, name: "list.json").flatMap(SupportApi.decodeSummaries)
    }

    static func saveList(userId: String, tickets: [SupportTicketSummary]) {
        write(userId: userId, name: "list.json", body: SupportApi.encodeSummaries(tickets))
    }

    static func loadTicket(userId: String, ticketId: String) -> SupportTicket? {
        read(userId: userId, name: "ticket_\(ticketId).json").flatMap(SupportApi.decodeTicket)
    }

    static func saveTicket(userId: String, ticket: SupportTicket) {
        write(userId: userId, name: "ticket_\(ticket.id).json", body: SupportApi.encodeTicket(ticket))
    }

    static func removeTicket(userId: String, ticketId: String) {
        try? FileManager.default.removeItem(at: file(userId: userId, name: "ticket_\(ticketId).json"))
    }

    static func clearAll() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(dirName, isDirectory: true)
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static func read(userId: String, name: String) -> String? {
        let url = file(userId: userId, name: name)
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8)?.nilIfBlank
        else { return nil }
        return s
    }

    private static func write(userId: String, name: String, body: String) {
        let url = file(userId: userId, name: name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func file(userId: String, name: String) -> URL {
        let safe = userId.replacingOccurrences(of: #"[^a-zA-Z0-9._-]"#, with: "_", options: .regularExpression)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        return root.appendingPathComponent(name)
    }
}

enum SupportMediaCache {
    private static let dirName = "support_media"
    private static let maxFiles = 80
    private static let maxBytes = 64 * 1024 * 1024

    static func load(_ key: String) -> Data? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    static func save(_ key: String, _ bytes: Data) {
        let url = file(key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: url, options: .atomic)
        trim()
    }

    private static func file(_ key: String) -> URL {
        let digest = key.utf8.reduce(UInt64(5381)) { (($0 << 5) &+ $0) &+ UInt64($1) }
        let name = String(format: "%016llx.bin", digest)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func trim() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(dirName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        var total = sorted.reduce(Int64(0)) { acc, u in
            acc + Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var i = 0
        while (sorted.count - i > maxFiles || total > maxBytes) && i < sorted.count {
            total -= Int64((try? sorted[i].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: sorted[i])
            i += 1
        }
    }
}

enum SupportStore {
    @MainActor
    static func clearOnSignOut() {
        SupportUnreadStore.shared.clear()
        SupportCacheStore.clearAll()
    }
}
