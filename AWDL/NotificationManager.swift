import Foundation
import UserNotifications

// MARK: - NotificationManager
// Thin wrapper around UNUserNotificationCenter.
// Requests authorization once at startup; silently drops notifications if denied.

final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    /// Call once from applicationDidFinishLaunching.
    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                NSLog("NotificationManager: auth error — %@", error.localizedDescription)
            } else {
                NSLog("NotificationManager: authorization granted = %d", granted)
            }
        }
    }

    // MARK: - Send

    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("NotificationManager: delivery error — %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Allow banners to appear while the app is in the foreground (menu bar app is always "foreground").
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
