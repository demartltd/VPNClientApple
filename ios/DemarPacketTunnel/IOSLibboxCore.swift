import Foundation
import Libbox
import NetworkExtension

enum IOSLibboxCore {
    private static var commandServer: LibboxCommandServer?
    private static var platform: DemarLibboxPlatform?
    private static var isSetup = false

    static var isRunning: Bool { commandServer != nil }

    static func start(
        provider: NEPacketTunnelProvider,
        configJSON: String,
        excludedIPv4: [String],
        assetDir: URL
    ) throws {
        try verifyCoreVersion(assetDir: assetDir)
        try ensureSetup(assetDir: assetDir)
        if commandServer == nil {
            let platformInterface = DemarLibboxPlatform(provider: provider, excludedIPv4: excludedIPv4)
            platform = platformInterface
            var error: NSError?
            let server = LibboxNewCommandServer(platformInterface, platformInterface, &error)
            if let error {
                throw error
            }
            guard let server else {
                throw NSError(domain: "DemarLibbox", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Libbox command server creation returned nil.",
                ])
            }
            try server.start()
            commandServer = server
        } else {
            try platform?.reapplyExcludedIPv4(excludedIPv4)
        }
        LibboxSetMemoryLimit(true)
        truncateCoreLog()
        let options = LibboxOverrideOptions()
        try commandServer?.checkConfig(configJSON)
        try commandServer?.startOrReloadService(configJSON, options: options)
        ClashTrafficMonitor.start()
        VpnSharedStore.appendPendingUiDiagLine("[core] started version=\(LibboxVersion())")
    }

    private static func verifyCoreVersion(assetDir: URL) throws {
        let expectedTag = try String(
            contentsOf: assetDir.appendingPathComponent("bundled_version.txt"),
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedTag.hasPrefix("v") ? String(expectedTag.dropFirst()) : expectedTag
        let actual = LibboxVersion().trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == expected else {
            throw NSError(domain: "DemarLibbox", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Libbox version mismatch: expected \(expected), loaded \(actual).",
            ])
        }
    }

    static func reload(configJSON: String, excludedIPv4: [String]) throws {
        guard commandServer != nil else {
            throw NSError(domain: "DemarLibbox", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Libbox is not running.",
            ])
        }
        try platform?.reapplyExcludedIPv4(excludedIPv4)
        let options = LibboxOverrideOptions()
        try commandServer?.checkConfig(configJSON)
        try commandServer?.startOrReloadService(configJSON, options: options)
        ClashTrafficMonitor.start()
    }

    static func markSession(id: String, protocolName: String, endpoint: String) {
        let message = "[demar-session] id=\(id) core=\(LibboxVersion()) protocol=\(protocolName) endpoint=\(endpoint)"
        commandServer?.writeMessage(2, message: message)
        VpnSharedStore.appendPendingUiDiagLine("[core] \(message)")
    }

    /// Fresh core.log per connect so journal.sh --core/--tg is not drowned in weeks of noise.
    private static func truncateCoreLog() {
        guard let url = try? VpnAppGroup.coreLogFileURL() else { return }
        try? Data().write(to: url, options: .atomic)
    }

    static func activateTrafficCapture() throws {
        try platform?.activateTrafficCapture()
    }

    static func resumeDefaultInterfaceAfterCapture() {
        platform?.resumeDefaultInterfaceAfterCapture()
    }

    static func stop() {
        ClashTrafficMonitor.stop()
        try? commandServer?.closeService()
        commandServer?.close()
        commandServer = nil
        platform?.reset()
        platform = nil
    }

    private static func ensureSetup(assetDir: URL) throws {
        guard !isSetup else { return }
        let sharedDir = try VpnAppGroup.sharedDirectoryURL()
        let workingDir = assetDir
        let tempDir = sharedDir.appendingPathComponent("demar_vpn/libbox_tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let options = LibboxSetupOptions()
        options.basePath = sharedDir.path
        options.workingPath = workingDir.path
        options.tempPath = tempDir.path
        options.logMaxLines = 20_000
        options.debug = false

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError { throw setupError }
        isSetup = true
    }
}
