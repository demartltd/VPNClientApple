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
        let adBlock = TunSettingsStore.effectiveAdBlockEnabled(isFree: isFree)
        let tunFp = TunSettingsStore.fingerprint(isFree: isFree)
        let refreshAssets = Self.shouldRefreshAssets()
        let (plan, endpointAddresses, bypassExcludeIPs, configJson) = try await Task.detached(priority: .userInitiated) {
            let base = server.connectPlan
            let ips = try UplinkIPv4Resolver.resolve(base.uplinkHost)
            guard !ips.isEmpty else {
                throw NSError(domain: "DemarVpn", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "VPN endpoint has no IPv4 address.",
                ])
            }
            let exclude = BypassExcludeIPCache.load(fingerprint: tunFp) ?? []
            let plan = base.pinEndpoint(to: ips)
            let json = try SingBoxConfigBuilder.buildTunConfigJson(
                plan: plan,
                tunName: tunName,
                bypassHosts: bypassHosts,
                bypassExcludeIPs: exclude,
                adBlockEnabled: adBlock
            )
            return (plan, ips, exclude, json)
        }.value
        try VpnSharedStore.saveBypassGeoipTags(plan.geoipBypassTags)
        let sessionId = Self.newSessionId()
        await MainActor.run {
            AppLog.shared.append(
                "[vpn] connect tun=\(tunFp) hosts=\(bypassHosts.count) "
                    + "excludeIPs=\(bypassExcludeIPs.count) rs=\(plan.bypassRuleSets.count) "
                    + "adblock=\(adBlock) assetsRefresh=\(refreshAssets)"
            )
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            controller.connect(
                configJson: configJson,
                uplinkHost: plan.uplinkHost,
                uplinkIPv4s: endpointAddresses,
                vpnSessionId: sessionId,
                connectTriggerSource: "swiftApp",
                refreshAssetsFromBundle: refreshAssets,
                savePayload: true
            ) { c.resume(with: $0) }
        }
        Self.refreshBypassExcludes(hosts: bypassHosts, fingerprint: tunFp, uplinkIPs: endpointAddresses)
    }

    func disconnect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            controller.disconnect(triggerSource: "swiftApp") { c.resume(with: $0) }
        }
    }

    private static func shouldRefreshAssets() -> Bool {
        guard let dir = try? VpnAppGroup.assetDirectoryURL() else { return true }
        return CoreBundleAssets.needsRefresh(in: dir)
    }

    @MainActor
    private static func isFreeSubscription() -> Bool {
        let raw = (AuthSessionStore.session?.vpnSubscription ?? "free")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw.caseInsensitiveCompare("free") == .orderedSame
    }

    private static func newSessionId() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Off hot path: resolve site A → cache → reapply NE excludes if still connected.
    private static func refreshBypassExcludes(hosts: [String], fingerprint: String, uplinkIPs: [String]) {
        guard !hosts.isEmpty else { return }
        let ctrl = VpnTunnelController.shared
        Task.detached(priority: .utility) {
            let fresh = resolveBypassExcludeIPs(hosts)
            BypassExcludeIPCache.save(fingerprint: fingerprint, ips: fresh)
            let merged = Array(Set(uplinkIPs + fresh)).sorted()
            guard !merged.isEmpty else { return }
            ctrl.sendProviderCommand("reapplyExcludes:" + merged.joined(separator: ",")) { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        AppLog.shared.append("[vpn] bypass reapply excludeIPs=\(fresh.count)")
                    case .failure(let e):
                        AppLog.shared.append("[vpn] bypass reapply skip: \(e.localizedDescription)")
                    }
                }
            }
        }
    }

    private static func resolveBypassExcludeIPs(_ hosts: [String], maxIPs: Int = 128) -> [String] {
        let names = TunEffective.excludeResolveHosts(hosts)
        guard !names.isEmpty else { return [] }
        let lock = NSLock()
        var out = Set<String>()
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            guard let ips = try? UplinkIPv4Resolver.resolve(names[i]) else { return }
            lock.lock()
            for ip in ips where out.count < maxIPs { out.insert(ip) }
            lock.unlock()
        }
        return out.sorted()
    }
}
#endif
