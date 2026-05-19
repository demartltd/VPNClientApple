import Foundation

enum ThroughputFormatter {
    static func kilobytesPerSecond(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb <= 0 { return "0 KB/s" }
        if kb < 10 {
            return String(format: "%.1f KB/s", kb)
        }
        return String(format: "%.0f KB/s", kb)
    }
}
