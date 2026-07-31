import Foundation

enum ClashTrafficMonitor {
    private static var task: Task<Void, Never>?

    private static let trafficURL = URL(
        string: "http://\(SingBoxConfigConstants.clashApiHost):\(SingBoxConfigConstants.clashApiPort)/traffic"
    )!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    static func start() {
        stop()
        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await session.bytes(from: trafficURL)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { return }
                        guard let sample = ClashTraffic.parse(line) else { continue }
                        VpnSharedStore.saveThroughput(up: sample.up, down: sample.down)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    static func stop() {
        task?.cancel()
        task = nil
        VpnSharedStore.clearThroughput()
    }
}
