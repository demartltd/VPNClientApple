#if os(macOS)
import Foundation

struct MockVpnControlling: VpnControlling {
    func connect(server: ServerProfile) async throws {
        try await Task.sleep(nanoseconds: MockVpnService.connectDelayNs)
    }

    func disconnect() async throws {
        try await Task.sleep(nanoseconds: MockVpnService.disconnectDelayNs)
    }
}
#endif
