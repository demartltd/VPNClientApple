#if os(iOS) || os(macOS)
import Foundation
import NetworkExtension
#if os(iOS)
import WidgetKit
#endif

/// Observes the app's packet-tunnel `NEVPNConnection` and maps status into UI state.

@MainActor

final class VpnStatusMonitor {
    var onStatusChange: ((VpnConnectionState) -> Void)?
    private let controller = VpnTunnelController.shared
    private var connectionObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var darwinObserverToken: UnsafeMutableRawPointer?
    private var pollTimer: Timer?
    private var lastDeliveredState: VpnConnectionState?
    private weak var trackedConnection: NEVPNConnection?
    private var connectAttemptActive = false
    private var connectingSince: Date?
    private var disconnectingSince: Date?
    private var connectFailureGraceTask: Task<Void, Never>?
    private var lastTrackedNeStatus: NEVPNStatus?
    private var disconnectFlickerGraceUntil: Date?
    private var refreshGeneration = 0
    private static let connectTimeout: TimeInterval = 45
    private static let disconnectFlickerGrace: TimeInterval = 2
    private static let connectedHoldHeartbeatMaxAge: TimeInterval = 10
    private static let connectStallTimeout: TimeInterval = 10
    private static let extensionLaunchTimeout: TimeInterval = 3
    private static let connectProbeIntervalNs: UInt64 = 400_000_000
    private static let connectProbeAttempts = 30
    func start() {
        VpnSharedStore.clearStaleControlState()
        #if os(iOS)
        controller.disableOnDemandAutoReconnect { _ in }
        #endif
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus(reason: "ne-config", force: true)
            }
        }
        darwinObserverToken = VpnStatusSignal.observe { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.connectAttemptActive, !self.controller.isConnectInFlight else { return }
                self.refreshStatus(reason: "app-group", force: true, reloadPreferences: false)
                #if os(iOS)
                self.reloadVpnControls()
                #endif
            }
        }
        refreshStatus(reason: "start")
        startPolling()
    }
    func beginConnectAttempt() {
        connectFailureGraceTask?.cancel()
        connectAttemptActive = true
        connectingSince = Date()
        lastDeliveredState = nil
        startConnectProbe()
    }
    private func startConnectProbe() {
        connectFailureGraceTask = Task { @MainActor in
            for attempt in 0..<Self.connectProbeAttempts {
                try? await Task.sleep(nanoseconds: Self.connectProbeIntervalNs)
                guard !Task.isCancelled, self.connectAttemptActive else { return }
                self.logConnectTrace("probe-\(attempt)")
                Self.importPendingDiagLines()
                if let failure = Self.resolveFailureState() {
                    self.finishConnectAttempt(failure, logReason: "connect-probe-\(attempt)")
                    return
                }
                if let since = self.connectingSince,
                   Self.shouldFailStalledConnect(elapsed: Date().timeIntervalSince(since))
                {
                    self.finishConnectAttempt(
                        Self.resolveFailureState() ?? .error(message: Self.connectFailedMessage()),
                        logReason: "connect-stall"
                    )
                    return
                }
            }
        }
    }
    private func finishConnectAttempt(_ state: VpnConnectionState, logReason: String) {
        logConnectSnapshot(logReason)
        connectFailureGraceTask?.cancel()
        connectFailureGraceTask = nil
        connectAttemptActive = false
        connectingSince = nil
        publish(state, neStatus: trackedConnection?.status ?? .disconnected, logReason: logReason)
    }
    private func logConnectTrace(_ tag: String) {
        let elapsed = connectingSince.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
        let hb = Self.heartbeatSummary()
        let control = VpnSharedStore.loadControlState() ?? "none"
        let ne: String = if let status = trackedConnection?.status {
            Self.neStatusLabel(status)
        } else {
            "no-connection"
        }
        AppLog.shared.append("[vpn] trace (\(tag)): ne=\(ne) heartbeat=\(hb) control=\(control) elapsed=\(elapsed)s")
    }
    private func logConnectSnapshot(_ reason: String) {
        AppLog.shared.importSharedJournal()
        logConnectTrace(reason)
        #if os(macOS)
        AppLog.shared.append("[vpn] pluginkit: \(MacVpnDiag.pluginkitSummary())")
        AppLog.shared.append("[vpn] \(MacVpnDiag.codesignLine())")
        AppLog.shared.append("[vpn] bundle: \(MacVpnDiag.embeddedAppexSummary())")
        #endif
        let journal = VpnSharedStore.recentJournalLines(16)
        if journal.isEmpty {
            AppLog.shared.append("[vpn] journal: empty — extension process did not write diagnostics")
        } else {
            AppLog.shared.append("[vpn] journal tail (\(journal.count) lines):")
            for line in journal {
                AppLog.shared.append(line)
            }
        }
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
    private static func heartbeatSummary() -> String {
        guard let snapshot = VpnSharedStore.extensionHeartbeatSnapshot() else { return "none" }
        let phase = snapshot["phase"] ?? "none"
        let updatedAt = snapshot["updatedAt"] ?? ""
        guard !updatedAt.isEmpty else { return phase }
        return "\(phase)@\(updatedAt)"
    }
    func endConnectAttempt() {
        connectFailureGraceTask?.cancel()
        connectFailureGraceTask = nil
        connectAttemptActive = false
        connectingSince = nil
    }
    func stop() {
        connectFailureGraceTask?.cancel()
        connectFailureGraceTask = nil
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
            self.connectionObserver = nil
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        VpnStatusSignal.removeObserver(darwinObserverToken)
        darwinObserverToken = nil
        pollTimer?.invalidate()
        pollTimer = nil
        trackedConnection = nil
    }
    /// Imports extension journal, stop-reason history, and core log tail (e.g. when app becomes active).
    func importForegroundDiagnostics() {
        AppLog.shared.importSharedJournal()
        Self.importPendingDiagLines()
        importCoreTailIfNeeded()
        for line in VpnSharedStore.drainTunnelStopReasonHistoryAndClear() where !line.isEmpty {
            AppLog.shared.append(line)
        }
        if let stop = VpnSharedStore.drainLastTunnelStopReasonAndClear() {
            let label = stop["label"] ?? ""
            let code = stop["code"] ?? ""
            let uptime = stop["uptimeSinceStartSec"] ?? ""
            AppLog.shared.append("[vpn] tunnel stop (foreground): label=\(label) code=\(code) uptimeSec=\(uptime)")
        }
    }

    func refreshStatus(reason: String, force: Bool = false, reloadPreferences: Bool = true) {
        refreshGeneration += 1
        let generation = refreshGeneration
        if force {
            lastDeliveredState = nil
        }
        controller.refreshDemarStatus(reloadPreferences: reloadPreferences) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.refreshGeneration == generation else { return }
                switch result {
                case let .failure(error):
                    self.retargetObserver(connection: nil)
                    AppLog.shared.append("[vpn] refresh (\(reason)): \(error.localizedDescription)")
                    self.publishResolvedStatus(neStatus: .disconnected, reason: reason)
                case let .success((manager, status)):
                    self.retargetObserver(connection: manager?.connection)
                    VpnSharedStore.reconcileControlState(with: status)
                    if manager == nil, status == .disconnected {
                        VpnSharedStore.clearStaleControlState()
                    }
                    self.publishResolvedStatus(neStatus: status, reason: reason)
                }
            }
        }
    }
    private func retargetObserver(connection: NEVPNConnection?) {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
            self.connectionObserver = nil
        }
        trackedConnection = connection
        guard let connection else { return }
        connectionObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus(reason: "nevpn", force: true, reloadPreferences: false)
            }
        }
    }

    #if os(iOS)
    private func reloadVpnControls() {
        ControlCenter.shared.reloadControls(ofKind: VpnControlConstants.kind)
    }
    #endif

    /// Ignores brief `NEVPNStatus.disconnected` while extension heartbeat is still fresh.
    private func shouldHoldConnectedDespiteNeDisconnected(_ neStatus: NEVPNStatus) -> Bool {
        guard neStatus == .disconnected, !connectAttemptActive else {
            disconnectFlickerGraceUntil = nil
            return false
        }
        guard case .connected = lastDeliveredState,
              VpnSharedStore.extensionSignalsAlive(maxAge: Self.connectedHoldHeartbeatMaxAge)
        else {
            disconnectFlickerGraceUntil = nil
            return false
        }
        let now = Date()
        if let until = disconnectFlickerGraceUntil {
            if now < until { return true }
            disconnectFlickerGraceUntil = nil
            return false
        }
        disconnectFlickerGraceUntil = now.addingTimeInterval(Self.disconnectFlickerGrace)
        return true
    }

    private func publishResolvedStatus(neStatus: NEVPNStatus, reason: String) {
        if shouldHoldConnectedDespiteNeDisconnected(neStatus) {
            return
        }
        let previousNeStatus = lastTrackedNeStatus
        lastTrackedNeStatus = neStatus
        if neStatus == .disconnected, !connectAttemptActive {
            VpnSharedStore.reconcileControlState(with: neStatus)
        }
        var resolved = Self.resolveStatus(
            neStatus: neStatus,
            sharedControlState: VpnSharedStore.loadControlState(),
            connectGrace: connectAttemptActive
        )
        if let failure = Self.resolveFailureState() {
            if connectAttemptActive {
                if neStatus == .disconnecting || Self.matchesError(resolved) {
                    finishConnectAttempt(failure, logReason: "\(reason)-failure")
                    return
                }
            } else if neStatus == .disconnecting || Self.matchesError(resolved) {
                finishConnectAttempt(failure, logReason: "\(reason)-failure")
                return
            }
        }
        if connectAttemptActive, case .connecting = resolved, let since = connectingSince {
            let elapsed = Date().timeIntervalSince(since)
            if elapsed > Self.connectTimeout {
                finishConnectAttempt(
                    .error(message: "Таймаут подключения VPN. Откройте журнал ([mac]/[core]) или удалите профиль в Системных настройках → VPN."),
                    logReason: "connect-timeout"
                )
                return
            }
            if Self.shouldFailStalledConnect(elapsed: elapsed),
               let failure = Self.resolveFailureState()
            {
                finishConnectAttempt(failure, logReason: "connect-stall-diag")
                return
            }
        } else if !connectAttemptActive, case .connecting = resolved, neStatus == .disconnected {
            resolved = .disconnected
        } else if case .connected = resolved {
            connectFailureGraceTask?.cancel()
            connectFailureGraceTask = nil
            connectAttemptActive = false
            connectingSince = nil
            disconnectingSince = nil
        } else if connectAttemptActive, neStatus == .disconnected {
            Self.importPendingDiagLines()
            if let failure = Self.resolveFailureState() {
                finishConnectAttempt(failure, logReason: reason)
                return
            }
            let elapsed = connectingSince.map { Date().timeIntervalSince($0) } ?? 0
            if elapsed >= Self.extensionLaunchTimeout,
               Self.shouldFailStalledConnect(elapsed: elapsed)
            {
                finishConnectAttempt(.error(message: Self.connectFailedMessage()), logReason: reason)
                return
            }
            // NE often flickers disconnected before the extension starts — keep connecting UI.
            resolved = .connecting
        } else if case .disconnected = resolved, !connectAttemptActive {
            connectingSince = nil
            disconnectingSince = nil
            if neStatus == .disconnected,
               Self.neWasEstablished(previousNeStatus),
               let failure = Self.resolveFailureState()
            {
                resolved = failure
            }
        } else if case .error = resolved {
            connectAttemptActive = false
            connectingSince = nil
            disconnectingSince = nil
        } else if case .disconnecting = resolved, !connectAttemptActive {
            if disconnectingSince == nil { disconnectingSince = Date() }
            if let since = disconnectingSince, Date().timeIntervalSince(since) > 5 {
                VpnSharedStore.saveControlState("disconnected", notify: false)
                resolved = .disconnected
                disconnectingSince = nil
            }
        }
        publish(resolved, neStatus: neStatus, logReason: reason)
    }
    private func publish(_ state: VpnConnectionState, neStatus: NEVPNStatus, logReason: String) {
        var state = state
        // Only promote disconnected → error while a connect attempt is active.
        // After user disconnect, stale journal/core lines must not surface as errors.
        if case .disconnected = state, connectAttemptActive, let failure = Self.resolveFailureState() {
            state = failure
        }
        if lastDeliveredState == state { return }
        lastDeliveredState = state
        mirrorControlState(state, neStatus: neStatus)
        AppLog.shared.append("[vpn] status (\(logReason)): \(Self.logLabel(state)) ne=\(Self.neStatusLabel(neStatus))")
        onStatusChange?(state)
    }

    private func mirrorControlState(_ state: VpnConnectionState, neStatus: NEVPNStatus) {
        switch state {
        case .error:
            VpnSharedStore.saveControlState("disconnected", notify: false)
        case .connected:
            if neStatus == .connected {
                VpnSharedStore.saveControlState("connected", notify: false)
            }
        default:
            VpnSharedStore.saveControlState(Self.controlStateKey(state), notify: false)
        }
    }
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.connectAttemptActive || self.controller.isConnectInFlight {
                    if let connection = self.trackedConnection {
                        self.publishResolvedStatus(neStatus: connection.status, reason: "poll-connect")
                    } else {
                        self.refreshStatus(reason: "poll-connect", reloadPreferences: false)
                    }
                } else {
                    self.refreshStatus(reason: "poll", reloadPreferences: false)
                }
                AppLog.shared.importSharedJournal()
                if self.connectAttemptActive {
                    Self.importPendingDiagLines()
                }
                self.importCoreTailIfNeeded()
            }
        }
    }
    private static func importPendingDiagLines() {
        AppLog.shared.importSharedJournal()
        for line in VpnSharedStore.drainPendingUiDiagLinesAndClear() where !line.isEmpty {
            AppLog.shared.append(line)
        }
    }
    private static func shouldFailStalledConnect(elapsed: TimeInterval) -> Bool {
        #if os(macOS)
        if elapsed < extensionLaunchTimeout { return false }
        if VpnSharedStore.extensionHeartbeatPhase() == nil { return true }
        if elapsed >= connectStallTimeout,
           VpnSharedStore.loadControlState()?.lowercased() != "connected"
        {
            return true
        }
        return false
        #else
        return elapsed >= connectStallTimeout
        #endif
    }
    private static func activeSessionStartedAt() -> Date? {
        guard let raw = VpnSharedStore.loadActiveSession()?["startedAt"], !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func journalLineIsAfterSessionStart(_ line: String, sessionStartedAt: Date) -> Bool {
        guard line.first == "[",
              let end = line.firstIndex(of: "]"),
              end > line.startIndex
        else { return true }
        let raw = String(line[line.index(after: line.startIndex)..<end])
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let ts = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return true }
        return ts >= sessionStartedAt.addingTimeInterval(-1)
    }

    /// Drains extension diagnostics and returns a user-facing error, if any.
    private static func resolveFailureState() -> VpnConnectionState? {
        AppLog.shared.importSharedJournal()
        for line in VpnSharedStore.drainPendingUiDiagLinesAndClear() where !line.isEmpty {
            AppLog.shared.append(line)
        }
        if let startError = VpnSharedStore.drainTunnelStartFailureAndClear() {
            return .error(message: startError)
        }
        if VpnSharedStore.extensionHeartbeatIsFresh(maxAge: 45) {
            return nil
        }
        let sessionStartedAt = activeSessionStartedAt()
        for line in VpnSharedStore.recentJournalLines(48).reversed() {
            if let sessionStartedAt, !journalLineIsAfterSessionStart(line, sessionStartedAt: sessionStartedAt) {
                continue
            }
            if isFailureDiagLine(line) {
                return .error(message: Self.diagLineMessage(line))
            }
        }
        for line in VpnSharedStore.drainTunnelStopReasonHistoryAndClear() where !line.isEmpty {
            AppLog.shared.append(line)
        }
        if let stop = VpnSharedStore.drainLastTunnelStopReasonAndClear() {
            let label = stop["label"] ?? ""
            let code = stop["code"] ?? ""
            let uptime = stop["uptimeSinceStartSec"] ?? ""
            let trigger = stop["triggerSource"] ?? ""
            AppLog.shared.append(
                "[vpn] tunnel stop: label=\(label) code=\(code) uptimeSec=\(uptime) source=\(trigger)"
            )
            if Self.isUserInitiatedStop(label: label, triggerSource: trigger) {
                return nil
            }
            if failureStopLabels.contains(label) {
                return .error(message: messageForStopLabel(label))
            }
        }
        return nil
    }

    private static func neWasEstablished(_ status: NEVPNStatus?) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        default:
            return false
        }
    }

    private static func isUserInitiatedStop(label: String, triggerSource: String) -> Bool {
        if label == "userInitiated", triggerSource.lowercased().contains("externaluserorsystem") {
            return false
        }
        if label == "userInitiated" { return true }
        let src = triggerSource.lowercased()
        if src.contains("hostappdisconnect") || src.contains("controlintent") { return true }
        return false
    }
    private static func isFailureDiagLine(_ line: String) -> Bool {
        let msg = diagLineMessage(line).lowercased()
        if line.contains("[core]") {
            if msg.contains("connection was refused"), VpnSharedStore.extensionSignalsAlive() {
                return false
            }
            return msg.contains("failed to start") || msg.contains(" failed")
                || msg.contains("error:") || msg.contains("fatal")
        }
        guard line.contains("[mac]") || line.contains("[ios]") else { return false }
        if msg.hasPrefix("post-start probe ") { return false }
        if msg.hasPrefix("tunnel stop:") { return false }
        if msg.contains("core subprocess started") { return false }
        if msg.contains("ne accepted start, but extension is not running") { return false }
        return msg.contains("error:") || msg.contains(" failed") || msg.hasPrefix("failed")
            || msg.contains(" missing") || msg.hasPrefix("missing")
            || msg.contains("could not") || msg.contains("core start error")
    }
    private static func diagLineMessage(_ line: String) -> String {
        for prefix in ["[mac] ", "[ios] ", "[core] ", "[vpn] "] {
            if let range = line.range(of: prefix) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return line
    }
    private static let failureStopLabels: Set<String> = [
        "configurationFailed",
        "configurationDisabled",
        "providerFailed",
        "connectionFailed",
        "unrecoverableNetworkChange",
        "noNetworkAvailable",
        "internalError",
        "idleTimeout",
        "sleep",
    ]
    private static func connectFailedMessage() -> String {
        #if os(macOS)
        if let block = MacVpnDiag.connectBlockReason() { return block }
        let hb = heartbeatSummary()
        if hb == "none" {
            return "\(MacVpnDiag.extensionNotStartedMessage)\n\(MacVpnDiag.codesignLine()). \(MacVpnDiag.gatekeeperLine()). \(MacVpnDiag.hostBundleLine())"
        }
        let tail = VpnSharedStore.recentJournalLines(3)
            .map { diagLineMessage($0) }
            .joined(separator: " | ")
        if !tail.isEmpty {
            return "Туннель не подключился (heartbeat=\(hb)): \(tail)"
        }
        return "Туннель не запустился (heartbeat=\(hb)). Проверьте Network Extensions/VPN в System Settings и откройте журнал ([mac]/[core])."
        #else
        return "Не удалось подключить VPN. Откройте журнал или перезапустите приложение."
        #endif
    }
    private static func messageForStopLabel(_ label: String) -> String {
        switch label {
        case "configurationDisabled":
            return "VPN-профиль отключен системой (configurationDisabled). Проверьте iOS Settings > VPN и включите Demar VPN снова."
        case "configurationFailed":
            return "Ошибка конфигурации VPN. Проверьте профиль и разрешение в Системных настройках → VPN."
        case "providerFailed":
            #if os(iOS)
            return "Туннель остановлен (core). Откройте журнал — строки [ios] и [core]."
            #else
            return "Туннель остановлен (core). Откройте журнал — строки [mac] и [core]."
            #endif
        case "connectionFailed":
            return "Не удалось установить VPN-соединение. Проверьте сеть и доступность сервера."
        case "unrecoverableNetworkChange":
            return "VPN отключился из‑за смены сети (Wi‑Fi/LTE). Подключитесь снова."
        case "noNetworkAvailable":
            return "VPN отключился: нет сети. Подключитесь снова, когда появится интернет."
        case "internalError":
            return "VPN остановлен системой (internalError). Откройте журнал."
        case "idleTimeout":
            return "VPN отключился по таймауту бездействия (idleTimeout)."
        case "sleep":
            return "VPN отключился при переходе устройства в сон. Проверьте профиль VPN (disconnectOnSleep)."
        default:
            return "VPN tunnel error (\(label))."
        }
    }
    private func importCoreTailIfNeeded() {
        for line in VpnSharedStore.readIncrementalSharedCoreLogLines() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            AppLog.shared.append("[core] \(text)")
        }
    }
    /// Maps NE status to UI state. App Group hints never override NE for connected/disconnected.
    private static func resolveStatus(
        neStatus: NEVPNStatus,
        sharedControlState: String?,
        connectGrace: Bool
    ) -> VpnConnectionState {
        switch neStatus {
        case .connected, .connecting, .reasserting, .disconnecting, .invalid:
            return map(neStatus)
        case .disconnected:
            if connectGrace {
                return .connecting
            }
            guard let shared = sharedControlState?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !shared.isEmpty
            else {
                return .disconnected
            }
            let fromShared = mapControlState(shared)
            if case .error = fromShared {
                return fromShared
            }
            return .disconnected
        @unknown default:
            return map(neStatus)
        }
    }
    private static func map(_ status: NEVPNStatus) -> VpnConnectionState {
        switch status {
        case .disconnected:
            return .disconnected
        case .connecting, .reasserting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        case .invalid:
            return .error(message: "VPN configuration invalid.")
        @unknown default:
            return .error(message: "Unknown VPN status.")
        }
    }
    private static func mapControlState(_ raw: String) -> VpnConnectionState {
        switch raw.lowercased() {
        case "connected":
            return .connected
        case "connecting":
            return .connecting
        case "disconnecting":
            return .disconnecting
        case "error":
            if let msg = VpnSharedStore.readTunnelStartFailureSnapshot(), !msg.isEmpty {
                return .error(message: msg)
            }
            return .error(message: "VPN tunnel error.")
        default:
            return .disconnected
        }
    }
    private static func controlStateKey(_ state: VpnConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        case .error: "error"
        }
    }
    private static func logLabel(_ state: VpnConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        case let .error(message): "error (\(message))"
        }
    }
    private static func matchesError(_ state: VpnConnectionState) -> Bool {
        if case .error = state { return true }
        return false
    }
}
#endif
