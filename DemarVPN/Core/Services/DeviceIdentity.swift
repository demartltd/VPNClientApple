import CryptoKit
import Foundation
#if os(iOS)
import AdSupport
import UIKit
#elseif os(macOS)
import IOKit
#endif

enum DeviceIdentity {
    static func load() async -> [(label: String, value: String)] {
        let raw = await Task.detached(priority: .utility) { collect() }.value
        var m = raw
        m["fingerprint_sha256"] = fingerprint(m)
        return rows(m)
    }

    private static func collect() -> [String: String] {
        #if os(iOS)
        let device = UIDevice.current
        return [
            "ios_version": device.systemVersion,
            "ios_model": iosModelCode(),
            "ios_locale": Locale.current.identifier,
            "ios_timezone": TimeZone.current.identifier,
            "idfv": device.identifierForVendor?.uuidString ?? "—",
            "idfa": IDFATracking.displayIDFA,
        ]
        #elseif os(macOS)
        let pi = ProcessInfo.processInfo
        return [
            "mac_computer_name": Host.current().localizedName ?? pi.hostName,
            "mac_os": pi.operatingSystemVersionString,
            "mac_hw_model": sysctl("hw.model") ?? "—",
            "mac_locale": Locale.current.identifier,
            "mac_timezone": TimeZone.current.identifier,
            "mac_hw_uuid": ioPlatformUUID() ?? "—",
        ]
        #else
        return [:]
        #endif
    }

    #if os(iOS)
    private static func iosModelCode() -> String {
        var uts = utsname()
        guard uname(&uts) == 0 else { return "—" }
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
    #endif

    #if os(macOS)
    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func ioPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let ref = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return (ref.takeRetainedValue() as? String)
    }
    #endif

    private static func fingerprint(_ m: [String: String]) -> String {
        #if os(macOS)
        if let u = m["mac_hw_uuid"], !u.isEmpty, u != "—" {
            return sha256Prefix32(u)
        }
        #endif
        let omit: Set<String> = ["fingerprint_sha256", "idfa"]
        let parts = m
            .filter { !omit.contains($0.key) && !$0.value.isEmpty && $0.value != "—" }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        return sha256Prefix32(parts.joined(separator: "|"))
    }

    private static func sha256Prefix32(_ s: String) -> String {
        let hex = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    private static let order = [
        "ios_version", "ios_model", "ios_locale", "ios_timezone", "idfv", "idfa",
        "mac_computer_name", "mac_os", "mac_hw_model",
        "mac_locale", "mac_timezone", "mac_hw_uuid",
        "fingerprint_sha256",
    ]

    private static func rows(_ m: [String: String]) -> [(String, String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for k in order where m[k] != nil {
            seen.insert(k)
            out.append((label(k), m[k]!))
        }
        for k in m.keys.sorted() where !seen.contains(k) {
            out.append((label(k), m[k]!))
        }
        return out
    }

    private static func label(_ k: String) -> String {
        switch k {
        case "ios_version": "iOS"
        case "ios_model": "Model"
        case "ios_locale": "Locale"
        case "ios_timezone": "Timezone"
        case "idfv": "IDFV"
        case "idfa": "IDFA"
        case "mac_computer_name": "Mac Name"
        case "mac_os": "macOS"
        case "mac_hw_model": "Model"
        case "mac_locale": "Locale"
        case "mac_timezone": "Timezone"
        case "mac_hw_uuid": "UUID"
        case "fingerprint_sha256": "Fingerprint"
        default: k
        }
    }
}
