import Foundation

/// Cross-process hint when extension or host updates App Group VPN state.
enum VpnStatusSignal {
  private static let darwinName = "com.demar.adblock.status" as CFString

  static func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(darwinName),
      nil,
      nil,
      true
    )
  }

  static func observe(onFire: @escaping () -> Void) -> UnsafeMutableRawPointer {
    let token = UnsafeMutableRawPointer(Unmanaged.passRetained(OnFireBox(onFire)).toOpaque())
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      token,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<OnFireBox>.fromOpaque(observer).takeUnretainedValue().onFire()
      },
      darwinName,
      nil,
      .deliverImmediately
    )
    return token
  }

  static func removeObserver(_ token: UnsafeMutableRawPointer?) {
    guard let token else { return }
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      token,
      CFNotificationName(darwinName),
      nil
    )
    Unmanaged<OnFireBox>.fromOpaque(token).release()
  }

  private final class OnFireBox {
    let onFire: () -> Void
    init(_ onFire: @escaping () -> Void) { self.onFire = onFire }
  }
}
