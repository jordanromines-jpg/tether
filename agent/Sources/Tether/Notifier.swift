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
