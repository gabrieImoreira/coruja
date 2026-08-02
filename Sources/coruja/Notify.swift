import Foundation
import UserNotifications

/// Best-effort user-visible notification. UNUserNotificationCenter shows
/// coruja's own icon (osascript's `display notification` gets attributed to
/// Script Editor instead, since that's the process actually calling the
/// notification API) — but it crashes outright (uncaught NSException,
/// "bundleProxyForCurrentProcess is nil") when there's no real .app bundle,
/// which is exactly the CLI/LaunchAgent install path this project also
/// supports. Confirmed live: running the raw binary crashed on the first
/// notification. Use UNUserNotificationCenter only inside a real .app;
/// fall back to osascript otherwise.
private let isRunningAsAppBundle = Bundle.main.bundleURL.pathExtension == "app"
private let center = isRunningAsAppBundle ? UNUserNotificationCenter.current() : nil
private var authorizationRequested = false

func notifyUser(title: String, body: String) {
    guard let center else {
        notifyViaOsascript(title: title, body: body)
        return
    }
    if !authorizationRequested {
        authorizationRequested = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

private func notifyViaOsascript(title: String, body: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title))"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
}
