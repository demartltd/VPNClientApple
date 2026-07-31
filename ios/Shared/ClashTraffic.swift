import Foundation

enum ClashTraffic {
    struct Sample: Equatable {
        let up: Int64
        let down: Int64
    }

    static func parse(_ line: String) -> Sample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let up = int64(obj["up"])
        let down = int64(obj["down"])
        guard let up, let down else { return nil }
        return Sample(up: up, down: down)
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}
