import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PlatformServices {
    static func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func lightImpact() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

#if os(macOS)
/// Thin facade over [`MacVpnDiag`](MacVpnDiag.swift) for Network Extension setup on macOS.
enum MacNetworkExtensionSetup {
    static let packetTunnelBundleId = MacVpnDiag.packetTunnelBundleId
    static let extensionPoint = MacVpnDiag.extensionPoint
    static let enableExtensionMessage = MacVpnDiag.enableExtensionMessage

    static var isPacketTunnelEnabled: Bool { MacVpnDiag.pluginkitStatus().isEnabled }

    static func registerEmbeddedExtensionIfNeeded() {
        _ = MacVpnDiag.syncHostInstallation()
    }

    static func openNetworkExtensionsSettings() {
        MacVpnDiag.openNetworkExtensionsSettings()
    }

    static func pluginkitSummary() -> String { MacVpnDiag.pluginkitSummary() }

    static func embeddedAppexSummary() -> String { MacVpnDiag.embeddedAppexSummary() }
}
#endif
