import Foundation
import Libbox
import Network
import NetworkExtension

private final class DarwinLocalDNSTransport: NSObject, LibboxLocalDNSTransportProtocol {
    func raw() -> Bool { false }

    func exchange(_: LibboxExchangeContext?, message _: Data?) throws {
        throw NSError(domain: "DemarLibbox", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "Raw local DNS exchange is unavailable.",
        ])
    }

    func lookup(_ ctx: LibboxExchangeContext?, network: String?, domain: String?) throws {
        guard let domain, !domain.isEmpty else {
            ctx?.errorCode(3)
            return
        }
        // IPv4-only uplink resolver: AAAA via local transport → empty (NXDOMAIN-ish).
        // IPv4-only TUN: Telegram DC IPv6 stays on physical; IPv4 DC goes through proxy.
        if network?.hasSuffix("6") == true {
            ctx?.success("")
            return
        }
        let addresses = try UplinkIPv4Resolver.resolve(domain)
        ctx?.success(addresses.joined(separator: "\n"))
    }
}

final class DemarLibboxPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var provider: NEPacketTunnelProvider?
    private var excludedIPv4: [String] = []
    private var configuredExcludedIPv4Routes: [NEIPv4Route] = []
    private var configuredBypassRoutes: [NEIPv4Route] = []
    private var configuredIncludedIPv4Routes: [NEIPv4Route] = []
    private var configuredDNSSettings: NEDNSSettings?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private let dnsTransport = DarwinLocalDNSTransport()
    private var nwMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "vpn.demar.iface-monitor", qos: .utility)
    private let reportFilter = DefaultInterfaceReportFilter()
    private var lastKnownPhysicalInterfaces: [LibboxNetworkInterface] = []
    private var lastGoodInterface: DefaultInterfaceUpdate?
    private var allowUnsatisfiedDefaultReport = false
    private var holdDefaultReportUntilSatisfied = false
    private weak var interfaceListener: LibboxInterfaceUpdateListenerProtocol?

    init(provider: NEPacketTunnelProvider, excludedIPv4: [String]) {
        self.provider = provider
        self.excludedIPv4 = excludedIPv4
    }

    func reapplyExcludedIPv4(_ addresses: [String]) throws {
        excludedIPv4 = addresses
        try libboxRunBlocking { [self] in
            guard let provider, let settings = networkSettings, let ipv4 = settings.ipv4Settings else {
                throw NSError(domain: "DemarLibbox", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "TUN network settings are not active.",
                ])
            }
            ipv4.excludedRoutes = Self.mergedIPv4Exclusions(
                configured: configuredExcludedIPv4Routes,
                runtimeAddresses: addresses,
                sidecars: configuredBypassRoutes
            )
            try await provider.setTunnelNetworkSettings(settings)
            Self.diag("reapplied endpoint bypass: \(addresses.joined(separator: ","))")
        }
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try libboxRunBlocking { [self] in
            try await openTun0(options, ret0_)
        }
    }

    func activateTrafficCapture() throws {
        try libboxRunBlocking { [self] in
            guard let provider, let settings = networkSettings, let ipv4 = settings.ipv4Settings else {
                throw NSError(domain: "DemarLibbox", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "TUN network settings are not active.",
                ])
            }
            // Full routes flap NE path unsatisfied — hold reports but keep en0 bound.
            // Libbox closes every conn on empty default iface (kills Hysteria2 QUIC).
            holdDefaultReportUntilSatisfied = true
            allowUnsatisfiedDefaultReport = false
            ipv4.includedRoutes = configuredIncludedIPv4Routes
            settings.dnsSettings = configuredDNSSettings
            settings.ipv6Settings = nil
            try await provider.setTunnelNetworkSettings(settings)
            Self.diag("traffic capture activated routes=\(configuredIncludedIPv4Routes.count)")
        }
    }

    /// Re-push physical default iface into libbox after capture path is settled.
    /// Do NOT reset the report filter — that re-sends identical en0 and libbox
    /// closes every conn (Hysteria2 QUIC → Telegram broken pipe).
    func resumeDefaultInterfaceAfterCapture() {
        holdDefaultReportUntilSatisfied = false
        // Full routes leave NE path .unsatisfied with en0 still listed — allow first report.
        allowUnsatisfiedDefaultReport = true
        guard let listener = interfaceListener, let path = nwMonitor?.currentPath else { return }
        updateDefaultInterface(listener, path: path)
    }

    private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let provider, let options, let ret0_ else {
            throw NSError(domain: "DemarLibbox", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing TUN options or provider.",
            ])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        guard options.getAutoRoute() else {
            throw NSError(domain: "DemarLibbox", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "TUN auto_route is required.",
            ])
        }

        settings.mtu = NSNumber(value: options.getMTU())

        let dnsServer = try Self.firstIPv4DNS(from: options)
        let dns = NEDNSSettings(servers: [dnsServer])
        // Split /1+/1 is not 0.0.0.0/0 — force DNS match so system DNS hits the tunnel.
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true

        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        let ipv4AddressIterator = options.getInet4Address()!
        while ipv4AddressIterator.hasNext() {
            let prefix = ipv4AddressIterator.next()!
            ipv4Addresses.append(prefix.address())
            ipv4Masks.append(prefix.mask())
        }

        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
        var ipv4Routes = Self.collectIPv4Routes(from: options)
        if ipv4Routes.isEmpty {
            ipv4Routes = [
                NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "128.0.0.0"),
                NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"),
            ]
        }

        var configuredExcludedRoutes: [NEIPv4Route] = []
        let ipv4ExcludeIterator = options.getInet4RouteExcludeAddress()!
        while ipv4ExcludeIterator.hasNext() {
            let prefix = ipv4ExcludeIterator.next()!
            configuredExcludedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
        configuredExcludedIPv4Routes = configuredExcludedRoutes
        configuredBypassRoutes = TunBypassCidrs.ipv4Routes(forTags: VpnSharedStore.loadBypassGeoipTags())
        let ipv4ExcludedRoutes = Self.mergedIPv4Exclusions(
            configured: configuredExcludedRoutes,
            runtimeAddresses: excludedIPv4,
            sidecars: configuredBypassRoutes
        )

        configuredIncludedIPv4Routes = ipv4Routes
        ipv4Settings.includedRoutes = []
        ipv4Settings.excludedRoutes = ipv4ExcludedRoutes
        settings.ipv4Settings = ipv4Settings
        // IPv4-only TUN (first Hysteria2): no inet6 in config → ipv6=off.
        settings.ipv6Settings = nil
        configuredDNSSettings = dns

        networkSettings = settings
        try await provider.setTunnelNetworkSettings(settings)
        Self.diag(
            "openTun mtu=\(options.getMTU()) dns=\(dns.servers.joined(separator: ",")) "
                + "routes=\(ipv4Routes.count) excluded=\(ipv4ExcludedRoutes.count) "
                + "bypassCidrs=\(configuredBypassRoutes.count) "
                + "ipv6=off capture=deferred"
        )

        if let tunFd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            Self.diag("openTun fd source=packetFlow")
            return
        }
        let tunFd = LibboxGetTunnelFileDescriptor()
        guard tunFd != -1 else {
            throw NSError(domain: "DemarLibbox", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Missing tunnel file descriptor.",
            ])
        }
        ret0_.pointee = tunFd
        Self.diag("openTun fd source=libbox")
    }

    private static func collectIPv4Routes(from options: LibboxTunOptionsProtocol) -> [NEIPv4Route] {
        var routes: [NEIPv4Route] = []
        appendIPv4Routes(from: options.getInet4RouteAddress(), into: &routes)
        if routes.isEmpty {
            appendIPv4Routes(from: options.getInet4RouteRange(), into: &routes)
        }
        return routes
    }

    private static func appendIPv4Routes(
        from iterator: LibboxRoutePrefixIteratorProtocol?,
        into routes: inout [NEIPv4Route]
    ) {
        guard let iterator else { return }
        while iterator.hasNext() {
            let prefix = iterator.next()!
            routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
    }

    private static func firstIPv4DNS(from options: LibboxTunOptionsProtocol) throws -> String {
        let iterator = try options.getDNSServerAddress()
        while iterator.hasNext() {
            return try validatedIPv4DNS(iterator.next())
        }
        throw NSError(domain: "DemarLibbox", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Missing synthetic IPv4 DNS address.",
        ])
    }

    private static func validatedIPv4DNS(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(":") else {
            throw NSError(domain: "DemarLibbox", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Invalid synthetic IPv4 DNS address: \(value)",
            ])
        }
        return trimmed
    }

    private static func mergedIPv4Exclusions(
        configured: [NEIPv4Route],
        runtimeAddresses: [String],
        sidecars: [NEIPv4Route] = []
    ) -> [NEIPv4Route] {
        var routes = configured
        var keys = Set(routes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" })
        for address in runtimeAddresses {
            let key = "\(address)/255.255.255.255"
            guard keys.insert(key).inserted else { continue }
            routes.append(NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255"))
        }
        for route in sidecars {
            let key = "\(route.destinationAddress)/\(route.destinationSubnetMask)"
            guard keys.insert(key).inserted else { continue }
            routes.append(route)
        }
        return routes
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func findConnectionOwner(
        _: Int32,
        sourceAddress _: String?,
        sourcePort _: Int32,
        destinationAddress _: String?,
        destinationPort _: Int32
    ) throws -> LibboxConnectionOwner {
        throw NSError(domain: "DemarLibbox", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Connection owner lookup is not implemented.",
        ])
    }

    func useProcFS() -> Bool { false }
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func checkPlatformShell() throws {}
    func tailscaleHostname() -> String { "" }
    func registerMyInterface(_: String?) {}
    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func cancelNotification(_: String?, typeID _: Int32) throws {}

    // Nonnull NSString + NSError** imports as NSErrorPointer (not throws).
    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = NSError(domain: "DemarLibbox", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "SFTP server lookup is not implemented.",
        ])
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = NSError(domain: "DemarLibbox", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "System SSH host key is unavailable.",
        ])
        return ""
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw NSError(domain: "DemarLibbox", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "User lookup is not implemented.",
        ])
    }

    func openShellSession(
        _: LibboxPlatformUser?,
        command _: String?,
        environ _: (any LibboxStringIteratorProtocol)?,
        term _: String?,
        rows _: Int32,
        cols _: Int32
    ) throws -> any LibboxShellSessionProtocol {
        throw NSError(domain: "DemarLibbox", code: 12, userInfo: [
            NSLocalizedDescriptionKey: "Shell session is not implemented.",
        ])
    }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw NSError(domain: "DemarLibbox", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "Bridge is not implemented.",
        ])
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        interfaceListener = listener
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var signaled = false
        let signalOnce = {
            lock.lock()
            defer { lock.unlock() }
            guard !signaled else { return }
            signaled = true
            semaphore.signal()
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateDefaultInterface(listener, path: path)
            // NE path is often .unsatisfied with en0 still listed — don't block on satisfied.
            if path.status == .satisfied
                || path.availableInterfaces.contains(where: { !PhysicalInterfaceSelector.isTunnelInterface($0.name) }) {
                signalOnce()
            }
        }
        monitor.start(queue: monitorQueue)
        // Prefer a real iface before first en0 report (avoids EADDRNOTAVAIL binds).
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            signalOnce()
            allowUnsatisfiedDefaultReport = true
            if let path = nwMonitor?.currentPath {
                updateDefaultInterface(listener, path: path)
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateDefaultInterface(listener, path: path)
        }
    }

    private func updateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, path: Network.NWPath) {
        let candidates = physicalInterfaceCandidates(from: path)
        let pathContext = Self.pathContext(from: path)
        let update = DefaultInterfaceResolver.resolve(
            candidates: candidates,
            path: pathContext,
            lastGood: lastGoodInterface
        )
        if DefaultInterfaceResolver.isLiveCandidate(update, candidates: candidates) {
            lastGoodInterface = update
            lastKnownPhysicalInterfaces = physicalLibboxInterfaces(from: candidates)
        }

        // Hold only during setTunnelNetworkSettings. Live phys iface must reach libbox
        // even when NE path stays .unsatisfied (steady state after full routes on iOS).
        if holdDefaultReportUntilSatisfied { return }
        if path.status == .unsatisfied, update.isLost, !allowUnsatisfiedDefaultReport { return }

        switch reportFilter.decide(update) {
        case let .report(update):
            send(update, to: listener)
        case .scheduleLoss:
            // Never forward .lost while the tunnel is up — libbox closes Hysteria2 +
            // Telegram MTProto. Keep last-reported phys iface until teardown.
            _ = reportFilter.confirmLoss(candidatesPresent: true)
        case .ignore:
            break
        }
    }

    private func send(_ update: DefaultInterfaceUpdate, to listener: LibboxInterfaceUpdateListenerProtocol) {
        Self.diag("defaultIface name=\(update.name.isEmpty ? "<lost>" : update.name) idx=\(update.index)")
        listener.updateDefaultInterface(
            update.name,
            interfaceIndex: update.index,
            isExpensive: update.isExpensive,
            isConstrained: update.isConstrained
        )
    }

    private func physicalLibboxInterfaces(from path: Network.NWPath) -> [LibboxNetworkInterface] {
        physicalLibboxInterfaces(from: physicalInterfaceCandidates(from: path))
    }

    private func physicalLibboxInterfaces(from candidates: [PhysicalInterfaceCandidate]) -> [LibboxNetworkInterface] {
        candidates.map { interface -> LibboxNetworkInterface in
            let item = LibboxNetworkInterface()
            item.name = interface.name
            item.index = interface.index
            switch interface.kind {
            case .wifi: item.type = LibboxInterfaceTypeWIFI
            case .cellular: item.type = LibboxInterfaceTypeCellular
            case .ethernet: item.type = LibboxInterfaceTypeEthernet
            default: item.type = LibboxInterfaceTypeOther
            }
            return item
        }
    }

    private func physicalInterfaceCandidates(from path: Network.NWPath) -> [PhysicalInterfaceCandidate] {
        path.availableInterfaces
            .filter { !PhysicalInterfaceSelector.isTunnelInterface($0.name) }
            .map { interface in
                PhysicalInterfaceCandidate(
                    name: interface.name,
                    index: Int32(interface.index),
                    kind: Self.kind(for: interface.type)
                )
            }
    }

    private static func pathContext(from path: Network.NWPath) -> DefaultInterfaceResolver.PathContext {
        DefaultInterfaceResolver.PathContext(
            isSatisfied: path.status != .unsatisfied,
            usesWifi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesEthernet: path.usesInterfaceType(.wiredEthernet),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private static func kind(for type: NWInterface.InterfaceType) -> PhysicalInterfaceKind {
        switch type {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .ethernet
        default: .other
        }
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        reportFilter.reset()
        interfaceListener = nil
        allowUnsatisfiedDefaultReport = false
        holdDefaultReportUntilSatisfied = false
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw NSError(domain: "DemarLibbox", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Default interface monitor has not started.",
            ])
        }
        guard nwMonitor.currentPath.status != .unsatisfied else {
            return DemarNetworkInterfaceIterator(lastKnownPhysicalInterfaces)
        }
        let interfaces = physicalLibboxInterfaces(from: nwMonitor.currentPath)
        if !interfaces.isEmpty {
            lastKnownPhysicalInterfaces = interfaces
        }
        return DemarNetworkInterfaceIterator(interfaces.isEmpty ? lastKnownPhysicalInterfaces : interfaces)
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func clearDNSCache() {
        Self.diag("clearDNSCache")
    }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func send(_: LibboxNotification?) throws {}
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { dnsTransport }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_: Bool) throws {}
    func serviceStop() throws {}
    func serviceReload() throws {}
    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "DemarLibbox", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "SSH agent is not implemented.",
        ])
    }
    func triggerNativeCrash() throws {
        throw NSError(domain: "DemarLibbox", code: 15, userInfo: [
            NSLocalizedDescriptionKey: "Native crash trigger is not implemented.",
        ])
    }

    func writeDebugMessage(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        VpnSharedStore.appendPendingUiDiagLine("[core] \(message)")
    }

    func reset() {
        reportFilter.reset()
        interfaceListener = nil
        allowUnsatisfiedDefaultReport = false
        holdDefaultReportUntilSatisfied = false
        nwMonitor?.cancel()
        nwMonitor = nil
        networkSettings = nil
        configuredExcludedIPv4Routes = []
        configuredBypassRoutes = []
        configuredIncludedIPv4Routes = []
        configuredDNSSettings = nil
        lastGoodInterface = nil
        lastKnownPhysicalInterfaces = []
    }

    private static func diag(_ message: String) {
        VpnSharedStore.appendPendingUiDiagLine("[tun] \(message)")
    }
}

private final class DemarNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ values: [LibboxNetworkInterface]) {
        iterator = values.makeIterator()
    }

    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? { nextValue }
}

