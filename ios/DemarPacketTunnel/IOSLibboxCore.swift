#if os(iOS)
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
            platform?.updateExcludedIPv4(excludedIPv4)
        }
        LibboxSetMemoryLimit(true)
        let options = LibboxOverrideOptions()
        try commandServer?.startOrReloadService(configJSON, options: options)
    }

    static func reload(configJSON: String, excludedIPv4: [String]) throws {
        guard commandServer != nil else {
            throw NSError(domain: "DemarLibbox", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Libbox is not running.",
            ])
        }
        platform?.updateExcludedIPv4(excludedIPv4)
        let options = LibboxOverrideOptions()
        try commandServer?.startOrReloadService(configJSON, options: options)
    }

    static func stop() {
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
        options.logMaxLines = 1000
        options.debug = false

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError { throw setupError }
        isSetup = true
    }
}

#endif
