import AppKit
import TetherCore

let env = ProcessInfo.processInfo.environment
let port = Int(env["TETHER_PORT"] ?? "") ?? 7400
let devMode = env["TETHER_DEV"] == "1"
let policy = AuthPolicy(allowedLoginsList: env["TETHER_ALLOWED_LOGINS"] ?? "", devMode: devMode)
let webDirectory = env["TETHER_WEB_DIR"]
    ?? Bundle.main.resourceURL?.appendingPathComponent("web").path
    ?? "web"

if policy.allowedLogins.isEmpty && !devMode {
    NSLog("Tether: TETHER_ALLOWED_LOGINS is empty — every request will be refused.")
}

let app = NSApplication.shared
let delegate = AppDelegate(port: port, publicURL: env["TETHER_PUBLIC_URL"])
app.delegate = delegate
app.setActivationPolicy(.accessory)

Task.detached {
    do {
        try await Server.run(port: port, webDirectory: webDirectory, policy: policy, publicURL: env["TETHER_PUBLIC_URL"])
        // Graceful shutdown (SIGTERM/SIGINT) finished; end the AppKit run loop too.
        exit(0)
    } catch {
        NSLog("Tether: server failed: \(error)")
        exit(1)
    }
}

app.run()
