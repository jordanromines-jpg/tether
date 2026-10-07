import AppKit
import TetherCore

// `Tether --make-alias <folder>`: used by scripts/shortcut.sh (also over SSH) to add a Finder
// alias to this app without scripting Finder. Runs before the single-instance check on purpose.
if let i = CommandLine.arguments.firstIndex(of: "--make-alias") {
    let folder = CommandLine.arguments.dropFirst(i + 1).first ?? Shortcuts.defaultFolder.path
    do {
        print(try Shortcuts.addAlias(in: URL(fileURLWithPath: folder)).path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if SingleInstance.otherInstanceRunning() {
    NSLog("Tether: already running; this copy exits.")
    exit(0)
}

let config = AppConfig.load()
let policy = AuthPolicy(allowedLoginsList: config.allowedLogins, devMode: config.devMode)

// Dev mode only: TETHER_DEV_PASSKEY=1 turns the passkey lock on and opens enrollment, so the
// Face ID flow can be tested end to end without the menu bar.
if config.devMode && ProcessInfo.processInfo.environment["TETHER_DEV_PASSKEY"] == "1" {
    PasskeyStore.shared.setRequired(true)
    PasskeyStore.shared.openEnrollment()
}

if policy.allowedLogins.isEmpty && !config.devMode {
    NSLog("Tether: no allowed logins configured (run scripts/setup.sh); every request will be refused.")
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
