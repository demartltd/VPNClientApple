import Foundation
import Darwin

enum UplinkIPv4Resolver {
  private static let lock = NSLock()
  private static var cache: [String: (ips: [String], at: Date)] = [:]
  private static let ttl: TimeInterval = 300

  static func clear() {
    lock.lock()
    cache.removeAll()
    lock.unlock()
  }

  static func resolve(_ host: String?) throws -> [String] {
    let clean = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !clean.isEmpty else { return [] }
    var literal = in_addr()
    if clean.withCString({ inet_pton(AF_INET, $0, &literal) }) == 1 { return [clean] }

    lock.lock()
    if let hit = cache[clean], Date().timeIntervalSince(hit.at) < ttl {
      let ips = hit.ips
      lock.unlock()
      return ips
    }
    lock.unlock()

    var hints = addrinfo(
      ai_flags: AI_DEFAULT,
      ai_family: AF_INET,
      ai_socktype: SOCK_STREAM,
      ai_protocol: 0,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(clean, nil, &hints, &result)
    guard code == 0 else {
      throw NSError(domain: "DemarVpn", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "DNS lookup failed for \(clean): \(String(cString: gai_strerror(code)))",
      ])
    }
    defer { if let result { freeaddrinfo(result) } }

    var addresses = Set<String>()
    var cursor = result
    while let info = cursor?.pointee {
      if info.ai_family == AF_INET,
         let socketAddress = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 })
      {
        var address = socketAddress.pointee.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
          addresses.insert(String(cString: buffer))
        }
      }
      cursor = info.ai_next
    }
    guard !addresses.isEmpty else {
      throw NSError(domain: "DemarVpn", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "DNS lookup returned no IPv4 for \(clean).",
      ])
    }
    let sorted = addresses.sorted()
    lock.lock()
    cache[clean] = (sorted, Date())
    lock.unlock()
    return sorted
  }
}
