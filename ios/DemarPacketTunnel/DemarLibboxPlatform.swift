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
        guard network?.hasSuffix("6") != true else {
            ctx?.errorCode(3)
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
    private var configuredIncludedIPv4Routes: [NEIPv4Route] = []
    private var configuredDNSSettings: NEDNSSettings?
    private var configuredIPv6Settings: NEIPv6Settings?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private let dnsTransport = DarwinLocalDNSTransport()
    private var nwMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "vpn.demar.iface-monitor", qos: .utility)
    private let reportFilter = DefaultInterfaceReportFilter()
    private var lossDebounceWork: DispatchWorkItem?
    private var lastKnownPhysicalInterfaces: [LibboxNetworkInterface] = []
    private var lastGoodInterface: DefaultInterfaceUpdate?

    private static let lossDebounceInterval: TimeInterval = 3

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
                runtimeAddresses: addresses
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
            ipv4.includedRoutes = configuredIncludedIPv4Routes
            settings.dnsSettings = configuredDNSSettings
            settings.ipv6Settings = configuredIPv6Settings
            try await provider.setTunnelNetworkSettings(settings)
            Self.diag("traffic capture activated routes=\(configuredIncludedIPv4Routes.count)")
        }
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

        var dnsSettings: NEDNSSettings?
        let dnsServer = try options.getDNSServerAddress()
        let dns = NEDNSSettings(servers: [try Self.validatedIPv4DNS(dnsServer.value)])
        dnsSettings = dns

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
        let ipv4ExcludedRoutes = Self.mergedIPv4Exclusions(
            configured: configuredExcludedRoutes,
            runtimeAddresses: excludedIPv4
        )

        configuredIncludedIPv4Routes = ipv4Routes
        ipv4Settings.includedRoutes = []
        ipv4Settings.excludedRoutes = ipv4ExcludedRoutes
        settings.ipv4Settings = ipv4Settings
        configuredIPv6Settings = Self.makeIPv6Settings(from: options)

        if !Self.hasDefaultIPv4Route(ipv4Routes) {
            dnsSettings?.matchDomains = [""]
            dnsSettings?.matchDomainsNoSearch = true
        }
        configuredDNSSettings = dnsSettings

        networkSettings = settings
        try await provider.setTunnelNetworkSettings(settings)
        Self.diag(
            "openTun mtu=\(options.getMTU()) dns=\(dns.servers.joined(separator: ",")) "
                + "routes=\(ipv4Routes.count) excluded=\(ipv4ExcludedRoutes.count) capture=deferred"
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

    private static func hasDefaultIPv4Route(_ routes: [NEIPv4Route]) -> Bool {
        routes.contains { $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0" }
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
        runtimeAddresses: [String]
    ) -> [NEIPv4Route] {
        var routes = configured
        var keys = Set(routes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" })
        for address in runtimeAddresses {
            let key = "\(address)/255.255.255.255"
            guard keys.insert(key).inserted else { continue }
            routes.append(NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255"))
        }
        return routes
    }

    private static func makeIPv6Settings(from options: LibboxTunOptionsProtocol) -> NEIPv6Settings? {
        var addresses: [String] = []
        var prefixes: [NSNumber] = []
        let addressIterator = options.getInet6Address()!
        while addressIterator.hasNext() {
            let prefix = addressIterator.next()!
            addresses.append(prefix.address())
            prefixes.append(NSNumber(value: prefix.prefix()))
        }
        guard !addresses.isEmpty else { return nil }

        let settings = NEIPv6Settings(addresses: addresses, networkPrefixLengths: prefixes)
        var included: [NEIPv6Route] = []
        let routeIterator = options.getInet6RouteAddress()!
        while routeIterator.hasNext() {
            let prefix = routeIterator.next()!
            included.append(NEIPv6Route(
                destinationAddress: prefix.address(),
                networkPrefixLength: NSNumber(value: prefix.prefix())
            ))
        }
        settings.includedRoutes = included.isEmpty ? [NEIPv6Route.default()] : included

        var excluded: [NEIPv6Route] = []
        let excludeIterator = options.getInet6RouteExcludeAddress()!
        while excludeIterator.hasNext() {
            let prefix = excludeIterator.next()!
            excluded.append(NEIPv6Route(
                destinationAddress: prefix.address(),
                networkPrefixLength: NSNumber(value: prefix.prefix())
            ))
        }
        settings.excludedRoutes = excluded
        return settings
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

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateDefaultInterface(listener, path: path)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.updateDefaultInterface(listener, path: path)
            }
        }
        monitor.start(queue: monitorQueue)
        semaphore.wait()
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

        switch reportFilter.decide(update) {
        case let .report(update):
            lossDebounceWork?.cancel()
            lossDebounceWork = nil
            send(update, to: listener)
        case .scheduleLoss:
            scheduleLossReport(listener)
        case .ignore:
            break
        }
    }

    private func scheduleLossReport(_ listener: LibboxInterfaceUpdateListenerProtocol) {
        lossDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let confirmed = self.reportFilter.confirmLoss() else { return }
            self.send(confirmed, to: listener)
        }
        lossDebounceWork = work
        monitorQueue.asyncAfter(deadline: .now() + Self.lossDebounceInterval, execute: work)
    }

    private func send(_ update: DefaultInterfaceUpdate, to listener: LibboxInterfaceUpdateListenerProtocol) {
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
        lossDebounceWork?.cancel()
        lossDebounceWork = nil
        reportFilter.reset()
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
    func clearDNSCache() {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func send(_: LibboxNotification?) throws {}
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { dnsTransport }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_: Bool) throws {}
    func serviceStop() throws {}
    func serviceReload() throws {}

    func writeDebugMessage(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        VpnSharedStore.appendPendingUiDiagLine("[core] \(message)")
    }

    func reset() {
        lossDebounceWork?.cancel()
        lossDebounceWork = nil
        reportFilter.reset()
        nwMonitor?.cancel()
        nwMonitor = nil
        networkSettings = nil
        configuredExcludedIPv4Routes = []
        configuredIncludedIPv4Routes = []
        configuredDNSSettings = nil
        configuredIPv6Settings = nil
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

