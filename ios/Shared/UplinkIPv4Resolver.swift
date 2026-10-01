import Foundation
import Darwin

enum UplinkIPv4Resolver {
  private static let lock = NSLock()
  private static var cache: [String: (ips: [String], at: Date)] = [:]
  private static let ttl: TimeInterval = 300

  static func clear() {
    lock.lock(); cache.removeAll(); lock.unlock()
  }

  static func resolve(_ host: String?) throws -> [String] {
    let clean = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !clean.isEmpty else { return [] }
    var lit = in_addr()
    if clean.withCString({ inet_pton(AF_INET, $0, &lit) }) == 1 { return [clean] }

    lock.lock()
    if let hit = cache[clean], Date().timeIntervalSince(hit.at) < ttl {
      let ips = hit.ips; lock.unlock(); return ips
    }
    lock.unlock()

    // Post-VPN-teardown DNS is flaky; retry like Android resolveUplinkIpv4s(attempts=2).
    for attempt in 0..<2 {
      if let ips = raceA(clean), !ips.isEmpty {
        return store(clean, ips)
      }
      if attempt == 0 {
        Thread.sleep(forTimeInterval: 0.15)
      }
    }
    throw NSError(domain: "DemarVpn", code: 10, userInfo: [
      NSLocalizedDescriptionKey: "DNS lookup failed for \(clean).",
    ])
  }

  /// DNS answer → A records (testable).
  static func parseARecords(_ data: Data, expectedID: UInt16) -> [String] {
    guard data.count >= 12 else { return [] }
    let b = [UInt8](data)
    let id = UInt16(b[0]) << 8 | UInt16(b[1])
    let flags = UInt16(b[2]) << 8 | UInt16(b[3])
    guard id == expectedID, flags & 0x8000 != 0, flags & 0xF == 0 else { return [] }
    let qd = Int(UInt16(b[4]) << 8 | UInt16(b[5]))
    let an = Int(UInt16(b[6]) << 8 | UInt16(b[7]))
    guard qd >= 1, an >= 1 else { return [] }
    var i = 12
    for _ in 0..<qd {
      guard skipName(b, &i), i + 4 <= b.count else { return [] }
      i += 4
    }
    var out = Set<String>()
    for _ in 0..<an {
      guard skipName(b, &i), i + 10 <= b.count else { break }
      let typ = UInt16(b[i]) << 8 | UInt16(b[i + 1])
      let rd = Int(UInt16(b[i + 8]) << 8 | UInt16(b[i + 9]))
      i += 10
      guard i + rd <= b.count else { break }
      if typ == 1, rd == 4 {
        out.insert("\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])")
      }
      i += rd
    }
    return out.sorted()
  }

  private static func store(_ host: String, _ ips: [String]) -> [String] {
    lock.lock(); cache[host] = (ips, Date()); lock.unlock()
    return ips
  }

  /// getaddrinfo ∥ UDP 1.1.1.1 (~1.5s); miss → 8.8.8.8.
  private static func raceA(_ host: String) -> [String]? {
    let box = NSLock()
    var win: [String]?
    func take(_ ips: [String]) {
      guard !ips.isEmpty else { return }
      box.lock(); if win == nil { win = ips }; box.unlock()
    }
    let g = DispatchGroup()
    g.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { g.leave() }
      take((try? gaiA(host)) ?? [])
    }
    g.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { g.leave() }
      take((try? udpA(host, "1.1.1.1")) ?? [])
    }
    _ = g.wait(timeout: .now() + 1.6)
    box.lock(); let early = win; box.unlock()
    if let early { return early }
    take((try? udpA(host, "8.8.8.8")) ?? [])
    _ = g.wait(timeout: .now() + 0.5)
    box.lock(); defer { box.unlock() }; return win
  }

  private static func gaiA(_ host: String) throws -> [String] {
    var hints = addrinfo(
      ai_flags: AI_DEFAULT, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
      ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0 else { throw dnsErr(host) }
    defer { if let result { freeaddrinfo(result) } }
    var out = Set<String>()
    var cur = result
    while let info = cur?.pointee {
      if info.ai_family == AF_INET,
         let sa = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
        var a = sa.pointee.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
          out.insert(String(cString: buf))
        }
      }
      cur = info.ai_next
    }
    guard !out.isEmpty else { throw dnsErr(host) }
    return out.sorted()
  }

  private static func udpA(_ host: String, _ server: String) throws -> [String] {
    let id = UInt16.random(in: 1...UInt16.max)
    let q = buildQuery(host, id)
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw dnsErr(host) }
    defer { close(fd) }
    var tv = timeval(tv_sec: 1, tv_usec: 500_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(53).bigEndian
    guard server.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { throw dnsErr(host) }
    let sent = q.withUnsafeBytes { raw -> Int in
      guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
      return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, p, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    guard sent == q.count else { throw dnsErr(host) }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = recv(fd, &buf, buf.count, 0)
    let ips = n > 0 ? parseARecords(Data(buf.prefix(n)), expectedID: id) : []
    guard !ips.isEmpty else { throw dnsErr(host) }
    return ips
  }

  private static func buildQuery(_ host: String, _ id: UInt16) -> Data {
    var out = Data([UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    for label in host.split(separator: ".") {
      let bytes = Array(label.utf8)
      guard bytes.count <= 63 else { continue }
      out.append(UInt8(bytes.count))
      out.append(contentsOf: bytes)
    }
    out.append(contentsOf: [0, 0x00, 0x01, 0x00, 0x01])
    return out
  }

  private static func skipName(_ b: [UInt8], _ i: inout Int) -> Bool {
    while i < b.count {
      let len = Int(b[i])
      if len == 0 { i += 1; return true }
      if len & 0xC0 == 0xC0 { guard i + 1 < b.count else { return false }; i += 2; return true }
      i += 1 + len
    }
    return false
  }

  private static func dnsErr(_ host: String) -> NSError {
    NSError(domain: "DemarVpn", code: 10, userInfo: [
      NSLocalizedDescriptionKey: "DNS lookup failed for \(host).",
    ])
  }
}
