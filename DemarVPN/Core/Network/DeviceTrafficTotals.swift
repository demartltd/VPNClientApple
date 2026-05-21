import Darwin

/// Cumulative link-layer byte counters since boot (non-loopback `AF_LINK`), same as Flutter iOS bridge.
enum DeviceTrafficTotals {
    static func cumulativeRXTXBytes() -> (rx: UInt64, tx: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ptr = head
        while let cur = ptr {
            let iface = cur.pointee
            ptr = iface.ifa_next
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: iface.ifa_name)
            if name == "lo0" || name.hasPrefix("lo") { continue }
            guard let rawData = iface.ifa_data else { continue }
            let data = rawData.assumingMemoryBound(to: if_data.self)
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        return (rx, tx)
    }
}
