import Foundation

protocol VpnControlling: Sendable {
    func connect(server: ServerProfile) async throws
    func disconnect() async throws
}
