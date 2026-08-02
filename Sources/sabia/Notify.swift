import Foundation
import UserNotifications

/// Best-effort user-visible notification via UserNotifications, so it's
/// attributed to sabia's own icon in Notification Center. The previous
/// osascript `display notification` approach (kept when sabia was a raw
/// binary with no bundle) shows the Script Editor icon instead — osascript
/// is the one actually calling the notification API, and macOS attributes
/// it to that process, not to sabia.
private let center = UNUserNotificationCenter.current()
private var authorizationRequested = false

func notifyUser(title: String, body: String) {
    if !authorizationRequested {
        authorizationRequested = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}
