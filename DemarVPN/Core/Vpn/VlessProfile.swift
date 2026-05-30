import Foundation

struct VlessProfile: Equatable, Sendable {
    let displayName: String
    let serverAddress: String
    let serverPort: Int
    let userId: String
    let encryption: String
    let flow: String?
    let network: String
    let security: String
    let query: [String: String]

    static func normalizeNetwork(_ raw: String) -> String {
        switch raw.lowercased() {
        case "splithttp", "split-http":
            return "xhttp"
        case "raw":
            return "tcp"
        default:
            return raw.lowercased()
        }
    }
}
