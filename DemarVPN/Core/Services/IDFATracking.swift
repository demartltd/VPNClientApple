import Foundation
#if os(iOS)
import AppTrackingTransparency
import AdSupport
import UIKit
#endif

#if os(iOS)
enum IDFATracking {
    static var isAuthorized: Bool {
        ATTrackingManager.trackingAuthorizationStatus == .authorized
    }

    static var showPermissionButton: Bool {
        ATTrackingManager.trackingAuthorizationStatus != .authorized
    }

    static var displayIDFA: String {
        ASIdentifierManager.shared().advertisingIdentifier.uuidString
    }

    @MainActor
    static func promptIfNeeded() async {
        try? await Task.sleep(for: .milliseconds(450))
        guard UIApplication.shared.applicationState == .active else { return }

        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized, .restricted, .denied:
            return
        case .notDetermined:
            _ = await ATTrackingManager.requestTrackingAuthorization()
        @unknown default:
            return
        }
    }

    @MainActor
    static func requestPermission() async -> Bool {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await ATTrackingManager.requestTrackingAuthorization() == .authorized
        case .denied, .restricted:
            openAppSettings()
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

}
#endif
