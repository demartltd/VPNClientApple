import Foundation

struct VlessRealityProfile: Equatable, Sendable {
    let displayName: String
    let serverAddress: String
    let serverPort: Int
    let userId: String
    let transport: String
    let sni: String
    let fingerprint: String
    let publicKey: String
    let shortId: String
    let flow: String?
}
