#if os(iOS) || os(macOS)
import Foundation

final class NativeVpnService: VpnControlling, @unchecked Sendable {
    private let controller = VpnTunnelController.shared

    func connect(server: ServerProfile) async throws {
        #if os(macOS)
        let tunSuffix = Int(Date().timeIntervalSince1970 * 1_000_000) & 0xFFFFFF
        let tunName = "utun\(tunSuffix)"
        #else
        let tunName = "utun0"
        #endif

        let plan = server.connectPlan
        let configJson = try SingBoxConfigBuilder.buildTunConfigJson(plan: plan, tunName: tunName)
        let sessionId = Self.newSessionId()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.connect(
                configJson: configJson,
                uplinkHost: plan.uplinkHost,
                vpnSessionId: sessionId,
                connectTriggerSource: "swiftApp",
                refreshAssetsFromBundle: true,
                savePayload: true
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    func disconnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.disconnect(triggerSource: "swiftApp") { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func newSessionId() -> String {
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
