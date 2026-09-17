#if os(iOS) || os(macOS)
import Foundation

final class NativeVpnService: VpnControlling, @unchecked Sendable {
    private let controller = VpnTunnelController.shared

    func connect(server: ServerProfile) async throws {
        let tunName = "utun0"
        let isFree = await MainActor.run { Self.isFreeSubscription() }
        if TunSettingsStore.currentCatalog.siteGroups.isEmpty {
            await MainActor.run { AppLog.shared.append("[tun] catalog empty — soft-fetch") }
            if let payload = await TunGroupsApi.fetch() {
                TunSettingsStore.cacheGroups(
                    payload.catalog,
                    raw: payload.raw,
                    userId: await MainActor.run { AuthSessionStore.session?.userId }
                )
            }
        }
        let bypassHosts = TunSettingsStore.effectiveBypassHosts(isFree: isFree)
        let tunFp = TunSettingsStore.fingerprint(isFree: isFree)
        let refreshAssets = Self.shouldRefreshAssets()
        let prepared = try await Task.detached(priority: .userInitiated) {
            let basePlan = server.connectPlan
            let endpointAddresses = try UplinkIPv4Resolver.resolve(basePlan.uplinkHost)
            guard !endpointAddresses.isEmpty else {
                throw NSError(domain: "DemarVpn", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "VPN endpoint has no IPv4 address.",
                ])
            }
            // Site bypass on Apple NE = route_exclude (like geoip), not outbound:direct.
            let bypassExcludeIPs = Self.resolveBypassExcludeIPs(bypassHosts)
            let plan = basePlan.pinEndpoint(to: endpointAddresses)
            return (
                plan,
                endpointAddresses,
                bypassExcludeIPs,
                try SingBoxConfigBuilder.buildTunConfigJson(
                    plan: plan,
                    tunName: tunName,
                    bypassHosts: bypassHosts,
                    bypassExcludeIPs: bypassExcludeIPs
                )
            )
        }.value
        let plan = prepared.0
        let endpointAddresses = prepared.1
        let bypassExcludeIPs = prepared.2
        let configJson = prepared.3
        try VpnSharedStore.saveBypassGeoipTags(plan.geoipBypassTags)
        let sessionId = Self.newSessionId()
        await MainActor.run {
            AppLog.shared.append(
                "[vpn] connect tun=\(tunFp) hosts=\(bypassHosts.count) "
                    + "excludeIPs=\(bypassExcludeIPs.count) rs=\(plan.bypassRuleSets.count) "
                    + "assetsRefresh=\(refreshAssets)"
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.connect(
                configJson: configJson,
                uplinkHost: plan.uplinkHost,
                uplinkIPv4s: endpointAddresses,
                vpnSessionId: sessionId,
                connectTriggerSource: "swiftApp",
                refreshAssetsFromBundle: refreshAssets,
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

    /// After upgrade wipe, `bundled_version.txt` is gone → first connect always refreshes.
    private static func shouldRefreshAssets() -> Bool {
        guard let assetDir = try? VpnAppGroup.assetDirectoryURL() else { return true }
        return CoreBundleAssets.needsRefresh(in: assetDir)
    }

    @MainActor
    private static func isFreeSubscription() -> Bool {
        let raw = (AuthSessionStore.session?.vpnSubscription ?? "free")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw.caseInsensitiveCompare("free") == .orderedSame
    }

    private static func newSessionId() -> String {
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort A records for NE `excludedRoutes`. Failures skipped; CDN IPs that
    /// miss the list fall through to proxy (still load — no ENETUNREACH).
    private static func resolveBypassExcludeIPs(_ hosts: [String], maxIPs: Int = 128) -> [String] {
        guard !hosts.isEmpty else { return [] }
        let lock = NSLock()
        var out = Set<String>()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
            guard let ips = try? UplinkIPv4Resolver.resolve(hosts[index]) else { return }
            lock.lock()
            defer { lock.unlock() }
            for ip in ips where out.count < maxIPs {
                out.insert(ip)
            }
        }
        return out.sorted()
    }
}
#endif
