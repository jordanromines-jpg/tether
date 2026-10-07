import Foundation
import UserNotifications

/// Shows "iPhone connected" style banners on the Mac.
enum Notifier {
    /// Notifications need a real app bundle (dev builds run as a bare executable).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func updateFinished(ok: Bool, version: String, message: String, whatsNew: [String]) {
        post(title: ok ? "Tether is updated" : "Tether's update didn't finish",
             body: ok ? (whatsNew.first.map { "Now \(version): \($0)" } ?? "Now running \(version).") : message)
    }

    static func crashed(at date: Date?) {
        let when = date.map { Calendar.current.isDateInToday($0) ? $0.formatted(date: .omitted, time: .shortened) : $0.formatted(date: .abbreviated, time: .shortened) } ?? "earlier"
        post(title: "Tether quit unexpectedly (\(when))", body: "It's running again. The Tether menu can open a pre-filled problem report.")
    }

    private static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("Tether: notification failed: \(error.localizedDescription)") }
        }
    }

    static func connected(device: String, login: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(device) connected to Tether"
        content.body = "Signed in to Tailscale as \(login). Use the Tether menu to disconnect."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Tether: notification failed: \(error.localizedDescription)") }
        }
    }
}
