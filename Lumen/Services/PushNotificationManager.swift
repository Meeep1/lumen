import Foundation
import UIKit
import UserNotifications

/// Real push registration — separate from SocketManager's local-notification path, which only
/// ever fires while a socket is open. This is what makes a notification arrive while the app is
/// fully closed/backgrounded: request permission, register for a device token, hand that token
/// to the backend (POST /profile/push-token), which uses it via APNs (backend/src/utils/apns.ts).
@MainActor
class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private override init() {}

    /// Called contextually (after a user's first match, see DiscoveryView) rather than at
    /// launch — asking before there's any reason to receive a notification is a common
    /// dating-app anti-pattern and more likely to get a hard "Don't Allow" that can't be
    /// re-prompted. Safe to call again later: `requestAuthorization` only ever prompts once and
    /// silently returns the existing decision after that.
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func registerDeviceToken(_ deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                try await APIService.shared.registerPushToken(tokenString)
            } catch {
                print("Failed to register push token: \(error)")
            }
        }
    }
}
