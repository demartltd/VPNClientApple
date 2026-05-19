import Foundation

enum MockVpnService {
    static let connectDelayNs: UInt64 = 1_200_000_000
    static let disconnectDelayNs: UInt64 = 800_000_000

    /// Mock throughput when connected (bytes per second).
    static let mockDownloadBps: Double = 1_250_000
    static let mockUploadBps: Double = 420_000
}
