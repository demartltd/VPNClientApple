#if os(iOS) || os(macOS)
import Foundation

final class NativeVpnService: VpnControlling, @unchecked Sendable {
    private let controller = VpnTunnelController.shared

    func connect(server: ServerProfile) async throws {
        let tunName = "utun0"
        let prepared = try await Task.detached(priority: .userInitiated) {
            let basePlan = server.connectPlan
            let endpointAddresses = try UplinkIPv4Resolver.resolve(basePlan.uplinkHost)
            guard !endpointAddresses.isEmpty else {
                throw NSError(domain: "DemarVpn", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "VPN endpoint has no IPv4 address.",
                ])
            }
            let plan = basePlan.pinEndpoint(to: endpointAddresses)
            return (
                plan,
                try SingBoxConfigBuilder.buildTunConfigJson(plan: plan, tunName: tunName)
            )
        }.value
        let plan = prepared.0
        let configJson = prepared.1
        try VpnSharedStore.saveBypassGeoipTags(plan.geoipBypassTags)
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
