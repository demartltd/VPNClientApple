import Darwin
import Foundation

/// Poll until TCP connect to IPv4 host:port succeeds (OpenFlux host SOCKS readiness).
enum LoopbackPortWait {
  static let pollMs: UInt64 = 200
  static let hostReadyTimeoutMs: UInt64 = 12_000
  static let tunnelWaitTimeoutMs: UInt64 = 8_000
  static let defaultSocksHost = "127.0.0.1"
  static let defaultSocksPort = 11080

  static func normalizedSocks(host: String, port: Int) -> (String, Int) {
    let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
    return (h.isEmpty ? defaultSocksHost : h, port > 0 ? port : defaultSocksPort)
  }

  static func ready(host: String, port: Int, timeoutMs: UInt64) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
      if canConnect(host: host, port: port) { return true }
      usleep(useconds_t(pollMs * 1000))
    }
    return canConnect(host: host, port: port)
  }

  private static func canConnect(host: String, port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var tv = timeval(tv_sec: 0, tv_usec: 400_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return false }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return rc == 0
  }
}
