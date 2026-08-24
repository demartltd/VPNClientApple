import Foundation

/// Coalesce concurrent async work: same key → joiners await one in-flight task.
@MainActor
enum Flight {
    private static var tasks: [String: Task<Void, Never>] = [:]
    private static var throwing: [String: Task<Void, Error>] = [:]

    static func run(_ key: String, _ work: @escaping @MainActor () async -> Void) async {
        if let t = tasks[key] { await t.value; return }
        let t = Task { await work() }
        tasks[key] = t
        await t.value
        tasks[key] = nil
    }

    static func run(_ key: String, _ work: @escaping @MainActor () async throws -> Void) async throws {
        if let t = throwing[key] { try await t.value; return }
        let t = Task { try await work() }
        throwing[key] = t
        defer { throwing[key] = nil }
        try await t.value
    }

    static func forEachLimited<T>(
        _ items: [T],
        limit: Int = 3,
        _ body: @escaping @MainActor (T) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var n = 0
            for item in items {
                if n >= limit { await group.next(); n -= 1 }
                group.addTask { @MainActor in await body(item) }
                n += 1
            }
        }
    }
}

/// Off-main keyed coalesce with a return value (media downloads, etc.).
enum KeyedFlight {
    private actor Store {
        static let shared = Store()
        private var map: [String: Any] = [:]

        func run<T: Sendable>(_ key: String, _ work: @Sendable @escaping () async throws -> T) async throws -> T {
            if let t = map[key] as? Task<T, Error> { return try await t.value }
            let t = Task { try await work() }
            map[key] = t
            defer { map[key] = nil }
            return try await t.value
        }
    }

    static func run<T: Sendable>(_ key: String, _ work: @Sendable @escaping () async throws -> T) async throws -> T {
        try await Store.shared.run(key, work)
    }
}
