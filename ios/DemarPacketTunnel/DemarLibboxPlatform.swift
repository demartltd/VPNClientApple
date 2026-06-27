import Foundation
import Libbox
import Network
import NetworkExtension

final class DemarLibboxPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var provider: NEPacketTunnelProvider?
    private var excludedIPv4: [String] = []
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "vpn.demar.iface-monitor", qos: .utility)
    private let reportFilter = DefaultInterfaceReportFilter()
    private var lossDebounceWork: DispatchWorkItem?
    private var lastKnownPhysicalInterfaces: [LibboxNetworkInterface] = []

    private static let lossDebounceInterval: TimeInterval = 3

    init(provider: NEPacketTunnelProvider, excludedIPv4: [String]) {
        self.provider = provider
        self.excludedIPv4 = excludedIPv4
    }

    func updateExcludedIPv4(_ addresses: [String]) {
        excludedIPv4 = addresses
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try libboxRunBlocking { [self] in
            try await openTun0(options, ret0_)
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
        let dns = NEDNSSettings(servers: [Self.effectiveIPv4DNS(dnsServer.value)])
        settings.dnsSettings = dns
        dnsSettings = dns
        settings.ipv6Settings = Self.ipv6DisabledSettings()

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
            ipv4Routes = Self.splitIPv4IncludedRoutes
        }

        var ipv4ExcludedRoutes = excludedIPv4.map {
            NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
        }
        let ipv4ExcludeIterator = options.getInet4RouteExcludeAddress()!
        while ipv4ExcludeIterator.hasNext() {
            let prefix = ipv4ExcludeIterator.next()!
            ipv4ExcludedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }

        ipv4Settings.includedRoutes = ipv4Routes
        ipv4Settings.excludedRoutes = ipv4ExcludedRoutes
        settings.ipv4Settings = ipv4Settings

        if !Self.hasDefaultIPv4Route(ipv4Routes) {
            dnsSettings?.matchDomains = [""]
            dnsSettings?.matchDomainsNoSearch = true
            settings.dnsSettings = dnsSettings
        }

        networkSettings = settings
        try await provider.setTunnelNetworkSettings(settings)

        if let tunFd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }
        let tunFd = LibboxGetTunnelFileDescriptor()
        guard tunFd != -1 else {
            throw NSError(domain: "DemarLibbox", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Missing tunnel file descriptor.",
            ])
        }
        ret0_.pointee = tunFd
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

    private static func effectiveIPv4DNS(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(":") else { return "1.1.1.1" }
        return trimmed
    }

    private static func ipv6DisabledSettings() -> NEIPv6Settings {
        let settings = NEIPv6Settings(addresses: ["fdde:de4a:100::2"], networkPrefixLengths: [64])
        settings.includedRoutes = []
        settings.excludedRoutes = [NEIPv6Route.default()]
        return settings
    }

    private static let splitIPv4IncludedRoutes: [NEIPv4Route] = [
        NEIPv4Route(destinationAddress: "1.0.0.0", subnetMask: "255.0.0.0"),
        NEIPv4Route(destinationAddress: "2.0.0.0", subnetMask: "254.0.0.0"),
        NEIPv4Route(destinationAddress: "4.0.0.0", subnetMask: "252.0.0.0"),
        NEIPv4Route(destinationAddress: "8.0.0.0", subnetMask: "248.0.0.0"),
        NEIPv4Route(destinationAddress: "16.0.0.0", subnetMask: "240.0.0.0"),
        NEIPv4Route(destinationAddress: "32.0.0.0", subnetMask: "224.0.0.0"),
        NEIPv4Route(destinationAddress: "64.0.0.0", subnetMask: "192.0.0.0"),
        NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"),
    ]

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
        let update: DefaultInterfaceUpdate
        if let interface = preferredPhysicalInterface(from: path) {
            lastKnownPhysicalInterfaces = physicalLibboxInterfaces(from: path)
            update = DefaultInterfaceUpdate(
                name: interface.name,
                index: interface.index,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
        } else {
            update = .lost
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
        physicalInterfaceCandidates(from: path)
            .map { interface -> LibboxNetworkInterface in
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

    private func preferredPhysicalInterface(from path: Network.NWPath) -> PhysicalInterfaceCandidate? {
        PhysicalInterfaceSelector.preferred(
            from: physicalInterfaceCandidates(from: path),
            usesWifi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesEthernet: path.usesInterfaceType(.wiredEthernet)
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
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
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
        lastKnownPhysicalInterfaces = []
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

