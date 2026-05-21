#if os(macOS)
import Darwin
import Foundation

/// Running xray subprocess started via posix_spawn with an inherited utun fd.
final class MacXrayChild {
    let pid: pid_t
    private let stdoutReadFD: Int32
    private let stderrReadFD: Int32
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private let logLock = NSLock()
    private var logLines: [String] = []

    fileprivate init(pid: pid_t, stdoutReadFD: Int32, stderrReadFD: Int32) {
        self.pid = pid
        self.stdoutReadFD = stdoutReadFD
        self.stderrReadFD = stderrReadFD
    }

    var isRunning: Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return true }
        return false
    }

    var terminationStatus: Int32 {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid, let code = Self.normalExitCode(status) {
            return code
        }
        return -1
    }

    private static func normalExitCode(_ status: Int32) -> Int32? {
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return nil
    }

    func startLogReaders() {
        stdoutSource = makeLogSource(fd: stdoutReadFD)
        stderrSource = makeLogSource(fd: stderrReadFD)
        stdoutSource?.resume()
        stderrSource?.resume()
    }

    func stopLogReaders() {
        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil
        close(stdoutReadFD)
        close(stderrReadFD)
    }

    func recentLogTail(maxLines: Int = 3) -> String {
        logLock.lock()
        defer { logLock.unlock() }
        return logLines.suffix(maxLines).joined(separator: " | ")
    }

    private func makeLogSource(fd: Int32) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            guard let text = String(bytes: buffer.prefix(count), encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                self.logLock.lock()
                self.logLines.append(trimmed)
                if self.logLines.count > 40 {
                    self.logLines.removeFirst(self.logLines.count - 40)
                }
                self.logLock.unlock()
                VpnSharedStore.appendPendingUiDiagLine("[xray] \(trimmed)")
            }
        }
        return source
    }
}

enum MacXrayProcess {
    /// Child fd number xray reads via XRAY_TUN_FD (must match env and dup2 target).
    private static let childTunFd: Int32 = 3

    @discardableResult
    static func start(configPath: String, tunFd: Int64, assetDir: String) throws -> MacXrayChild {
        let exe = try resolveExecutable()
        let parentTunFd = Int32(tunFd)
        guard parentTunFd >= 0 else {
            throw NSError(domain: "DemarVpn", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "Invalid utun file descriptor.",
            ])
        }
        try validateUtunFd(parentTunFd)

        VpnSharedStore.appendPendingUiDiagLine(
            "[mac] xray path=\(exe.path) spawn tun parentFd=\(parentTunFd) childFd=\(childTunFd)"
        )

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw NSError(domain: "DemarVpn", code: 26, userInfo: [
                NSLocalizedDescriptionKey: "pipe() failed (errno \(errno)).",
            ])
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closePipeEnds(outPipe)
            closePipeEnds(errPipe)
            throw NSError(domain: "DemarVpn", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "posix_spawn_file_actions_init failed.",
            ])
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        posix_spawn_file_actions_addclose(&actions, errPipe[1])
        let devNull = "/dev/null"
        devNull.withCString { devNullPath in
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, devNullPath, O_RDONLY, mode_t(0))
        }
        posix_spawn_file_actions_adddup2(&actions, parentTunFd, childTunFd)

        let argv = [exe.path, "run", "-c", configPath]
        var env = ProcessInfo.processInfo.environment
        env["XRAY_TUN_FD"] = String(childTunFd)
        env["XRAY_LOCATION_ASSET"] = assetDir
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let spawnStatus: Int32 = exe.path.withCString { exePath in
            argv.withSpawnArgv { argvPtr in
                envPairs.withSpawnEnvp { envPtr in
                    withUnsafePointer(to: &actions) { actionsPtr in
                        posix_spawn(&pid, exePath, actionsPtr, nil, argvPtr, envPtr)
                    }
                }
            }
        }

        close(outPipe[1])
        close(errPipe[1])

        guard spawnStatus == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw NSError(domain: "DemarVpn", code: 28, userInfo: [
                NSLocalizedDescriptionKey: "posix_spawn failed (errno \(spawnStatus)).",
            ])
        }

        let child = MacXrayChild(pid: pid, stdoutReadFD: outPipe[0], stderrReadFD: errPipe[0])
        child.startLogReaders()

        Thread.sleep(forTimeInterval: 0.25)
        if !child.isRunning {
            child.stopLogReaders()
            let tail = child.recentLogTail()
            let lastXray = VpnSharedStore.readLastXrayErrorLineSnapshot() ?? ""
            let humanDetail = [tail, lastXray]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            let code = child.terminationStatus
            let message = humanDetail?.isEmpty == false
                ? "xray завершился сразу после запуска (код \(code)): \(humanDetail!)"
                : "xray завершился сразу после запуска (код \(code))."
            VpnSharedStore.saveTunnelStartFailure(message)
            throw NSError(domain: "DemarVpn", code: 22, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        return child
    }

    static func stop(_ child: MacXrayChild?) {
        guard let child else { return }
        if child.isRunning {
            kill(child.pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3)
            while child.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if child.isRunning {
                kill(child.pid, SIGKILL)
                _ = waitpid(child.pid, nil, 0)
            }
        }
        child.stopLogReaders()
    }

    private static func validateUtunFd(_ fd: Int32) throws {
        var flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw NSError(domain: "DemarVpn", code: 29, userInfo: [
                NSLocalizedDescriptionKey: "utun fd \(fd) is not open (errno \(errno)).",
            ])
        }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private static func closePipeEnds(_ pipe: [Int32]) {
        if pipe[0] >= 0 { close(pipe[0]) }
        if pipe[1] >= 0 { close(pipe[1]) }
    }

    private static func resolveExecutable() throws -> URL {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("xray_macos") else {
            throw NSError(domain: "DemarVpn", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "xray_macos bundle folder missing in extension.",
            ])
        }
        let exe = dir.appendingPathComponent("xray")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw NSError(domain: "DemarVpn", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "xray binary missing in extension bundle.",
            ])
        }
        return exe
    }
}

private extension Array where Element == String {
    func withSpawnArgv<R>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
        let copies = map { strdup($0) }
        defer { copies.forEach { free($0) } }
        var pointers = copies.map { UnsafeMutablePointer(mutating: $0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }

    func withSpawnEnvp<R>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
        withSpawnArgv(body)
    }
}
#endif
