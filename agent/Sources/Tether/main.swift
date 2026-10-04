import AppKit
import TetherCore

if SingleInstance.otherInstanceRunning() {
    NSLog("Tether: already running; this copy exits.")
    exit(0)
}

let config = AppConfig.load()
let policy = AuthPolicy(allowedLoginsList: config.allowedLogins, devMode: config.devMode)

if policy.allowedLogins.isEmpty && !config.devMode {
    NSLog("Tether: no allowed logins configured (run scripts/setup.sh) — every request will be refused.")
}

let app = NSApplication.shared
let delegate = AppDelegate(port: config.port, publicURL: config.publicURL)
app.delegate = delegate
app.setActivationPolicy(.accessory)

Task.detached {
    do {
        try await Server.run(port: config.port, webDirectory: config.webDirectory, policy: policy, publicURL: config.publicURL)
        // Graceful shutdown (SIGTERM/SIGINT) finished; end the AppKit run loop too.
        exit(0)
    } catch {
        NSLog("Tether: server failed: \(error)")
        exit(1)
    }
}

app.run()
