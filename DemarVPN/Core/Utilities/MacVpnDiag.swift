#if os(macOS)
import AppKit
import CoreServices
import Foundation
import NetworkExtension
import Security

/// macOS packet-tunnel preflight: pluginkit, codesign, App Group, NE manager.
enum MacVpnDiag {
    static let packetTunnelBundleId = "com.demar.vpn.packet-tunnel"
    static let extensionPoint = "com.apple.networkextension.packet-tunnel"

    /// Shown only when pluginkit confirms the extension toggle is off.
    static let enableExtensionMessage =
        "Включите «Demar VPN» в System Settings → VPN (или в разделе Extensions/VPN, если он доступен в вашей версии macOS)."

    enum PluginkitStatus: Equatable {
        case enabled(detail: String)
        case disabled(detail: String)
        /// Sandbox cannot run pluginkit -m; connect is still allowed.
        case unverifiable(detail: String)
        case unknown(detail: String)

        var isEnabled: Bool {
            if case .enabled = self { return true }
            return false
        }

        var shouldOpenSystemSettings: Bool {
            if case .disabled = self { return true }
            return false
        }
    }

    static func pluginkitStatus() -> PluginkitStatus {
        // pluginkit -m is not available inside App Sandbox (PKDiscoverAll / discovery flags).
        .unverifiable(detail: "listing skipped in app sandbox (use Расширения сети in Settings)")
    }

    static func pluginkitSummary() -> String {
        switch pluginkitStatus() {
        case .enabled(let d): return "enabled; \(d)"
        case .disabled(let d): return "disabled; \(d)"
        case .unverifiable(let d): return "unverifiable (sandbox); \(d)"
        case .unknown(let d): return "unknown; \(d)"
        }
    }

    private static let hostBundlePathKey = "demar_vpn_host_bundle_path"
    private static let registeredAppexPathKey = "demar_vpn_registered_appex_path"
    private static let lastInstallBlockingIssueKey = "demar_vpn_install_blocking_issue"

    /// Registers this .app's appex with PlugInKit and disables stale copies (e.g. Xcode Debug vs build/macos-release).
    @discardableResult
    static func syncHostInstallation() -> String {
        let bundlePath = Bundle.main.bundlePath
        guard let appexPath = embeddedAppexURL()?.path, !appexPath.isEmpty else {
            return "install: appex missing"
        }
        let ud = UserDefaults.standard
        let lastBundle = ud.string(forKey: hostBundlePathKey)
        let lastAppex = ud.string(forKey: registeredAppexPathKey)
        var parts: [String] = []
        var installBlockingIssue: String?
        let hostMoved = lastBundle != nil && lastBundle != bundlePath
        let appexChanged = lastAppex != nil && lastAppex != appexPath
        let firstSync = lastBundle == nil || lastAppex == nil

        if hostMoved {
            parts.append("host moved")
            ud.set(true, forKey: shouldResetVPNProfileKey)
        }

        let requiresResync = firstSync || hostMoved || appexChanged
        if !requiresResync {
            ud.removeObject(forKey: lastInstallBlockingIssueKey)
            return parts.isEmpty ? "install: unchanged" : "install: \(parts.joined(separator: "; "))"
        }

        for stale in discoverStaleAppexPaths(current: appexPath, lastRegistered: lastAppex) {
            if let run = runPluginkit(arguments: ["-r", stale]) {
                parts.append("pluginkit -r \(shortPath(stale)) exit=\(run.exit)")
            }
        }

        parts.append(registerWithLaunchServices())

        if let run = runPluginkit(arguments: ["-a", appexPath]) {
            parts.append(run.exit == 0 ? "pluginkit -a: ok" : "pluginkit -a: exit=\(run.exit)")
            if run.exit != 0 { installBlockingIssue = "pluginkit -a exit=\(run.exit)" }
        } else {
            parts.append("pluginkit -a: spawn failed")
            installBlockingIssue = "pluginkit -a spawn failed"
        }

        if let run = runPluginkit(arguments: ["-e", "use", "-i", packetTunnelBundleId]) {
            if run.exit == 0 {
                parts.append("pluginkit -e use: ok")
            } else {
                // In sandboxed/dev launches this command may fail even when extension registration is valid.
                parts.append("pluginkit -e use: exit=\(run.exit) (manual toggle may be required)")
            }
        } else {
            parts.append("pluginkit -e use: spawn failed (manual toggle may be required)")
        }

        ud.set(appexPath, forKey: registeredAppexPathKey)
        ud.set(bundlePath, forKey: hostBundlePathKey)
        if let installBlockingIssue {
            ud.set(installBlockingIssue, forKey: lastInstallBlockingIssueKey)
        } else {
            ud.removeObject(forKey: lastInstallBlockingIssueKey)
        }
        return parts.isEmpty ? "install: ok" : "install: \(parts.joined(separator: "; "))"
    }

    private static let shouldResetVPNProfileKey = "demar_vpn_reset_ne_profile"

    static func consumeVPNProfileResetFlag() -> Bool {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: shouldResetVPNProfileKey) else { return false }
        ud.set(false, forKey: shouldResetVPNProfileKey)
        return true
    }

    static let extensionNotStartedMessage =
        "Туннель DemarPacketTunnel не запустился. 1) Включите Demar VPN в System Settings → VPN (или Extensions/VPN). "
        + "2) Удалите старый профиль «Demar VPN» в System Settings → VPN. "
        + "3) Перезапустите приложение и подключитесь снова."

    static func connectBlockReason() -> String? {
        if let gate = gatekeeperBlockReason() { return gate }
        if !codesignMatch() {
            return "Подпись приложения и расширения не совпадают. \(codesignLine()). Переустановите приложение."
        }
        if let installIssue = UserDefaults.standard.string(forKey: lastInstallBlockingIssueKey), !installIssue.isEmpty {
            return "Расширение сети не зарегистрировалось (\(installIssue)). \(enableExtensionMessage) Затем удалите профиль «Demar VPN» в System Settings → VPN и подключитесь снова."
        }
        return nil
    }

    static func gatekeeperLine() -> String {
        if gatekeeperBlockReason() != nil { return "gatekeeper: blocked (use notarized build or Right-click → Open once)" }
        return "gatekeeper: ok"
    }

    static func quarantineLine() -> String {
        let url = Bundle.main.bundleURL
        let props = try? url.resourceValues(forKeys: [.quarantinePropertiesKey])
        if props?.quarantineProperties != nil { return "quarantine: yes" }
        return "quarantine: no"
    }

    private static func gatekeeperBlockReason() -> String? {
        let url = Bundle.main.bundleURL
        if (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil {
            return "macOS заблокировал приложение (quarantine). ПКМ по Demar VPN → Open, или установите подписанную нотаризованную сборку."
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        guard SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
            != errSecSuccess
        else { return nil }
        return "Подпись приложения не принята системой. Нужна нотаризованная сборка (Developer ID) или ПКМ → Open для dev-сборки."
    }

    private static func registerWithLaunchServices() -> String {
        let status = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        return status == noErr ? "LSRegisterURL: ok" : "LSRegisterURL: \(status)"
    }

    static func codesignLine() -> String {
        guard let appex = embeddedAppexURL() else { return "codesign: appex missing" }
        let appTeam = teamID(for: Bundle.main.bundleURL) ?? "?"
        let appexTeam = teamID(for: appex) ?? "?"
        let match = appTeam != "?" && appTeam == appexTeam
        return "codesign: app=\(appTeam) appex=\(appexTeam) match=\(match ? "yes" : "no")"
    }

    static func codesignMatch() -> Bool {
        guard let appex = embeddedAppexURL(),
              let appTeam = teamID(for: Bundle.main.bundleURL),
              let appexTeam = teamID(for: appex)
        else { return false }
        return appTeam == appexTeam
    }

    static func appGroupProbeLine() -> String {
        guard let base = VpnAppGroup.containerURL else { return "app group: unavailable" }
        let probe = base.appendingPathComponent("demar_vpn/.diag_probe", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: probe.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ok".utf8).write(to: probe, options: [.atomic])
            try FileManager.default.removeItem(at: probe)
            return "app group: rw ok path=\(base.path)"
        } catch {
            return "app group: write failed (\(error.localizedDescription)) path=\(base.path)"
        }
    }

    static func embeddedAppexSummary() -> String {
        guard let appex = embeddedAppexURL() else { return "appex path unavailable" }
        let exe = appex.appendingPathComponent("Contents/MacOS/DemarPacketTunnel").path
        let fm = FileManager.default
        if !fm.fileExists(atPath: appex.path) { return "appex missing in bundle" }
        let coreOK = fm.isExecutableFile(atPath: exe)
        return "appex=\(appex.path) core=\(coreOK ? "ok" : "missing")"
    }

    static func neManagerSnapshot(_ manager: NETunnelProviderManager) -> String {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let provider = proto?.providerBundleIdentifier ?? "?"
        let status = neStatusLabel(manager.connection.status)
        let desc = manager.localizedDescription ?? "?"
        return "ne: enabled=\(manager.isEnabled) provider=\(provider) status=\(status) desc=\(desc)"
    }

    static func startupLines() -> [String] {
        let install = syncHostInstallation()
        return [
            appGroupProbeLine(), codesignLine(), gatekeeperLine(), quarantineLine(),
            embeddedAppexSummary(), "host=\(Bundle.main.bundlePath)", install,
        ]
    }

    static func hostBundleLine() -> String {
        "host=\(Bundle.main.bundlePath)"
    }

    static func openNetworkExtensionsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=\(extensionPoint)",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for raw in candidates {
            guard let url = URL(string: raw), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    // MARK: - Private

    private struct PluginkitRun {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    private static func embeddedAppexURL() -> URL? {
        Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("DemarPacketTunnel.appex", isDirectory: true)
    }

    private static func discoverStaleAppexPaths(current: String, lastRegistered: String?) -> [String] {
        var paths = Set<String>()
        if let lastRegistered, !lastRegistered.isEmpty, lastRegistered != current {
            paths.insert(lastRegistered)
        }
        let derivedRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: derivedRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix("DemarVPN-") {
                for config in ["Debug", "Release"] as [String] {
                    let candidate = entry
                        .appendingPathComponent("Build/Products/\(config)/DemarVPN.app/Contents/PlugIns/DemarPacketTunnel.appex")
                        .path
                    if candidate != current, FileManager.default.fileExists(atPath: candidate) {
                        paths.insert(candidate)
                    }
                }
            }
        }
        return Array(paths)
    }

    private static func shortPath(_ path: String) -> String {
        if path.contains("/DerivedData/") { return "Xcode-DerivedData-appex" }
        if path.contains("/build/macos-release/") { return "macos-release-appex" }
        return (path as NSString).lastPathComponent
    }

    private static func runPluginkit(arguments: [String]) -> PluginkitRun? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return PluginkitRun(exit: proc.terminationStatus, stdout: out, stderr: err)
    }

    private static func teamID(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func neStatusLabel(_ status: NEVPNStatus) -> String {
        switch status {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .reasserting: return "reasserting"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
        }
    }
}
#endif
