import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let port: Int
    private let publicURL: String?
    private var statusItem: NSStatusItem!
    private var clientCount = 0
    private var sessions: [ClientConnection] = []
    private var qrWindow: QRWindowController?

    init(port: Int, publicURL: String?) {
        self.port = port
        self.publicURL = publicURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        Hub.shared.onClientsChanged = { [weak self] list in
            self?.clientCount = list.count
            self?.sessions = list
            self?.updateIcon()
        }
        Permissions.requestMissing()
        Notifier.requestPermission()
    }

    private func updateIcon() {
        let paused = AppState.shared.paused
        let name = paused ? "pause.rectangle" : clientCount > 0 ? "display.and.arrow.down" : "display"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tether")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = paused ? "Tether — paused" : clientCount > 0 ? "Tether — \(clientCount) connected" : "Tether"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paused = AppState.shared.paused
        let header = NSMenuItem(title: paused ? "Tether — remote access paused"
                                    : clientCount == 0 ? "Tether — ready, nobody connected" : "Tether — \(clientCount) connected",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(item(paused ? "Resume remote access" : "Pause remote access", #selector(togglePause), key: "p"))
        if let publicURL {
            menu.addItem(item("Show QR code for your phone…", #selector(showQR)))
            menu.addItem(item("Copy link: \(publicURL)", #selector(copyLink)))
        }
        if !sessions.isEmpty {
            menu.addItem(.separator())
            let f = DateFormatter(); f.timeStyle = .short
            for c in sessions.sorted(by: { $0.connectedAt < $1.connectedAt }) {
                let i = NSMenuItem(title: "\(c.device) — \(c.login) — since \(f.string(from: c.connectedAt))", action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
            menu.addItem(item("Disconnect all", #selector(disconnectAll)))
        }
        menu.addItem(.separator())
        let store = PasskeyStore.shared
        let lockItem = item("Require Face ID / Touch ID passkey", #selector(togglePasskey))
        lockItem.state = store.required ? .on : .off
        menu.addItem(lockItem)
        if store.required {
            let n = store.credentials.count
            menu.addItem(item(store.enrolling ? "Adding passkeys is open — finish on your device" : "Add a passkey from a device… (opens for 10 min)",
                              #selector(openEnrollment)))
            if n > 0 { menu.addItem(item("Remove all \(n) passkey\(n == 1 ? "" : "s")", #selector(removePasskeys))) }
        }
        menu.addItem(.separator())
        menu.addItem(item("Screen Recording: \(Permissions.screenRecording ? "✓ allowed" : "✗ needed — open Settings")",
                          #selector(openScreenRecordingSettings)))
        menu.addItem(item("Accessibility: \(Permissions.accessibility ? "✓ allowed" : "✗ needed — open Settings")",
                          #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        if LoginItem.isInstalled {
            let login = item("Start Tether at login", #selector(toggleLoginItem))
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(item("Quit Tether (open it from Applications to start again)", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func showQR() {
        guard let publicURL else { return }
        if qrWindow == nil { qrWindow = QRWindowController(url: publicURL) }
        NSApp.activate(ignoringOtherApps: true)
        qrWindow?.showWindow(nil)
        qrWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyLink() {
        guard let publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL, forType: .string)
    }

    @objc private func openScreenRecordingSettings() {
        Permissions.requestMissing()
        Notifier.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        Permissions.requestMissing()
        Notifier.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func disconnectAll() { Hub.shared.disconnectAll() }

    @objc private func togglePasskey() {
        let store = PasskeyStore.shared
        store.setRequired(!store.required)
        if store.required { Hub.shared.disconnectAll() }  // everyone re-checks with the passkey
    }

    @objc private func openEnrollment() { PasskeyStore.shared.openEnrollment() }

    @objc private func removePasskeys() {
        PasskeyStore.shared.removeAll()
        PasskeyStore.shared.openEnrollment()
        Hub.shared.disconnectAll()
    }

    @objc private func togglePause() {
        AppState.shared.setPaused(!AppState.shared.paused)
        updateIcon()
    }

    @objc private func toggleLoginItem() { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func quit() { NSApp.terminate(nil) }
}
