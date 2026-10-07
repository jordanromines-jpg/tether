import AppKit
import Foundation

/// Where Tether keeps its settings: ~/Library/Application Support/Tether/.
enum AppPaths {
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}

/// Install-time settings written by scripts/lib/install-agent.sh (config.json).
/// Environment variables override them (used by scripts/dev.sh), so Tether starts the same
/// way whether launchd starts it at login or someone opens it from Applications.
struct AppConfig {
    let port: Int
    let allowedLogins: String
    let publicURL: String?
    let devMode: Bool
    let webDirectory: String
    /// A Tether checkout on this Mac that "Update now" rebuilds from (empty when another Mac installs it).
    let sourceDir: String?
    /// The Mac that builds and installs Tether here, named in the update banner.
    let updateFrom: String?

    static func load() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        let file = (try? Data(contentsOf: AppPaths.supportDirectory.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let port = Int(env["TETHER_PORT"] ?? "") ?? (file["port"] as? Int) ?? 7400
        let logins = env["TETHER_ALLOWED_LOGINS"] ?? (file["allowedLogins"] as? String) ?? ""
        let url = env["TETHER_PUBLIC_URL"] ?? (file["publicURL"] as? String)
        let web = env["TETHER_WEB_DIR"] ?? Bundle.main.resourceURL?.appendingPathComponent("web").path ?? "web"
        let text = { (key: String) in (file[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return AppConfig(port: port, allowedLogins: logins, publicURL: url, devMode: env["TETHER_DEV"] == "1", webDirectory: web,
                         sourceDir: env["TETHER_SOURCE_DIR"] ?? text("sourceDir"), updateFrom: text("updateFrom"))
    }
}

/// Runtime switches the person controls from the menu bar, persisted in state.json:
/// a paused Mac stays paused across restarts, and the Setup Assistant remembers it has run.
final class AppState {
    static let shared = AppState()
    private let lock = NSLock()
    private var pausedValue = false
    private var onboardedValue = false
    private var checkUpdatesValue = true
    private var url: URL { AppPaths.supportDirectory.appendingPathComponent("state.json") }

    private init() {
        if let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            pausedValue = (o["paused"] as? Bool) ?? false
            onboardedValue = (o["onboarded"] as? Bool) ?? false
            checkUpdatesValue = (o["checkUpdates"] as? Bool) ?? true
        }
    }

    var paused: Bool { lock.withLock { pausedValue } }
    var onboarded: Bool { lock.withLock { onboardedValue } }
    var checkUpdates: Bool { lock.withLock { checkUpdatesValue } }

    func setCheckUpdates(_ on: Bool) { lock.withLock { checkUpdatesValue = on; save() } }

    func setPaused(_ on: Bool) {
        lock.withLock { pausedValue = on; save() }
        if on { Hub.shared.disconnectAll() }
    }

    func setOnboarded() { lock.withLock { onboardedValue = true; save() } }

    /// Call with the lock held.
    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: ["paused": pausedValue, "onboarded": onboardedValue,
                                                                    "checkUpdates": checkUpdatesValue]) {
            try? d.write(to: url)
        }
    }
}

/// "Start at login": the LaunchAgent installed by setup, switched with launchctl enable/disable.
/// Quitting is separate: the agent only restarts Tether after a crash, never after Quit.
enum LoginItem {
    static let label = "com.tether.agent"
    private static var domain: String { "gui/\(getuid())" }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        guard isInstalled else { return false }
        let out = run(["print-disabled", domain])
        return !out.contains("\"\(label)\" => disabled") && !out.contains("\"\(label)\" => true")
    }

    static func setEnabled(_ on: Bool) {
        _ = run([on ? "enable" : "disable", "\(domain)/\(label)"])
        // Re-enabling also needs the job loaded again for the next login.
        if on { _ = run(["bootstrap", domain, NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"]) }
    }

    @discardableResult
    private static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Only one Tether at a time (e.g. it was opened from Applications while launchd already started it).
enum SingleInstance {
    static func otherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }
}
