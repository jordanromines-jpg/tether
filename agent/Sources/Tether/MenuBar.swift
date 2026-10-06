import AppKit
import SwiftUI
import TetherCore
import TetherUI

/// Tether's menu-bar icon. Left-click opens the status panel; right-click (or Control-click)
/// opens the classic menu, which is also the keyboard-friendly route.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let port: Int
    private let publicURL: String?
    private var statusItem: NSStatusItem!
    private var sessions: [ClientConnection] = []
    private var qrWindow: QRWindowController?
    private var setupWindow: SetupWindowController?
    private let popover = NSPopover()
    private let panel = PanelModel()
    private let menu = NSMenu()
    private var setupRequested = CommandLine.arguments.contains("--setup")
    private var panelTimer: Timer?

    init(port: Int, publicURL: String?) {
        self.port = port
        self.publicURL = publicURL
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // tether://setup opens the Setup Assistant, even when Tether is already running
        // (scripts/setup.sh uses it; `open --args` can't reach a running app).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: StatusPanelView(model: panel))
        panel.actions = panelActions()

        updateIcon()
        Hub.shared.onClientsChanged = { [weak self] list in
            self?.sessions = list
            self?.updateIcon()
            self?.refreshPanel()
        }
        Notifier.requestPermission()

        let open = SetupPolicy.shouldOpenAssistant(onboarded: AppState.shared.onboarded, requested: setupRequested,
                                                   screenAllowed: Permissions.screenRecording, inputAllowed: Permissions.accessibility)
        if open { showSetup() } else { Permissions.requestMissing() }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if url.host == "setup" {
            if statusItem == nil { setupRequested = true } else { showSetup() }
        }
    }

    // MARK: Icon

    private func updateIcon() {
        let paused = AppState.shared.paused
        statusItem.button?.image = MenuBarIcon.image(paused ? .paused : sessions.isEmpty ? .idle : .connected)
        statusItem.button?.toolTip = paused ? "Tether: paused" : sessions.isEmpty ? "Tether" : "Tether: \(sessions.count) connected"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // so the next left-click opens the panel again
        } else {
            togglePanel()
        }
    }

    // MARK: Panel

    private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        refreshPanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Keep "idle 12 min" labels fresh while the panel is open.
        panelTimer?.invalidate()
        panelTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.popover.isShown else { self?.panelTimer?.invalidate(); return }
            self.refreshPanel()
        }
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshPanel() {
        let store = PasskeyStore.shared
        panel.paused = AppState.shared.paused
        panel.url = publicURL
        panel.sessions = sessions.sorted { $0.connectedAt < $1.connectedAt }
            .map { SessionRow(id: $0.id, device: $0.device, login: $0.login, since: $0.connectedAt,
                              viewOnly: $0.observe, lastInput: $0.lastInput) }
        panel.curtainOn = Curtain.shared.isOn
        panel.screenAllowed = Permissions.screenRecording
        panel.inputAllowed = Permissions.accessibility
        panel.passkeyRequired = store.required
        panel.passkeyCount = store.credentials.count
        panel.enrolling = store.enrolling
        panel.loginItemInstalled = LoginItem.isInstalled
        panel.startAtLogin = LoginItem.isEnabled
    }

    private func panelActions() -> PanelActions {
        var a = PanelActions()
        a.setPaused = { [weak self] on in AppState.shared.setPaused(on); self?.updateIcon() }
        a.copyLink = { [weak self] in self?.copyLink() }
        a.showQR = { [weak self] in self?.popover.performClose(nil); self?.showQR() }
        a.disconnect = { id in Hub.shared.disconnect(id: id) }
        a.disconnectAll = { Hub.shared.disconnectAll() }
        a.setPasskeyRequired = { [weak self] on in self?.setPasskeyRequired(on) }
        a.openEnrollment = { [weak self] in PasskeyStore.shared.openEnrollment(); self?.refreshPanel() }
        a.removePasskeys = { [weak self] in self?.removePasskeys(); self?.refreshPanel() }
        a.openScreenRecording = { [weak self] in self?.popover.performClose(nil); self?.openScreenRecordingSettings() }
        a.openAccessibility = { [weak self] in self?.popover.performClose(nil); self?.openAccessibilitySettings() }
        a.setStartAtLogin = { on in LoginItem.setEnabled(on) }
        a.openSetup = { [weak self] in self?.popover.performClose(nil); self?.showSetup() }
        a.addShortcut = { [weak self] in self?.popover.performClose(nil); Shortcuts.addInteractively() }
        a.quit = { NSApp.terminate(nil) }
        a.setCurtain = { on in Curtain.shared.set(on) }
        a.openHelp = { [weak self] in self?.popover.performClose(nil); Self.open("help") }
        a.reportProblem = { [weak self] in self?.popover.performClose(nil); Self.open("issues") }
        return a
    }

    // MARK: Setup Assistant

    @objc private func showSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindowController()
            setupWindow?.onFinish = { [weak self] in
                // Show where Tether lives now that the window is gone.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.togglePanel() }
            }
        }
        setupWindow?.show()
    }

    // MARK: Classic menu (right-click)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paused = AppState.shared.paused
        let header = NSMenuItem(title: paused ? "Tether: remote access paused"
                                    : sessions.isEmpty ? "Tether: ready, nobody connected" : "Tether: \(sessions.count) connected",
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
                let i = NSMenuItem(title: "\(c.device), \(c.login), since \(f.string(from: c.connectedAt))", action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
            menu.addItem(item("Disconnect all", #selector(disconnectAll)))
        }
        menu.addItem(.separator())
        let store = PasskeyStore.shared
        let lockItem = item("Require Face ID or Touch ID passkey", #selector(togglePasskey))
        lockItem.state = store.required ? .on : .off
        menu.addItem(lockItem)
        if store.required {
            let n = store.credentials.count
            menu.addItem(item(store.enrolling ? "Adding passkeys is open. Finish on your device." : "Add a passkey from a device… (open for 10 min)",
                              #selector(openEnrollment)))
            if n > 0 { menu.addItem(item("Remove all \(n) passkey\(n == 1 ? "" : "s")", #selector(removePasskeys))) }
        }
        menu.addItem(.separator())
        menu.addItem(item("Screen Recording: \(Permissions.screenRecording ? "allowed" : "needed, open Settings")",
                          #selector(openScreenRecordingSettings)))
        menu.addItem(item("Accessibility: \(Permissions.accessibility ? "allowed" : "needed, open Settings")",
                          #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        if Curtain.shared.isOn { menu.addItem(item("Turn off curtain", #selector(curtainOff))) }
        menu.addItem(item("Setup Assistant…", #selector(showSetup)))
        menu.addItem(item("Help and docs", #selector(openHelp)))
        menu.addItem(item("Report a problem", #selector(reportProblem)))
        menu.addItem(item("Add a shortcut…", #selector(addShortcut)))
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
        SetupWindowController.openPrivacy("Privacy_ScreenCapture")
    }

    @objc private func openAccessibilitySettings() {
        Permissions.requestMissing()
        Notifier.requestPermission()
        SetupWindowController.openPrivacy("Privacy_Accessibility")
    }

    @objc private func disconnectAll() { Hub.shared.disconnectAll() }

    @objc private func togglePasskey() { setPasskeyRequired(!PasskeyStore.shared.required) }

    private func setPasskeyRequired(_ on: Bool) {
        PasskeyStore.shared.setRequired(on)
        if on { Hub.shared.disconnectAll() }  // everyone re-checks with the passkey
        refreshPanel()
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

    @objc private func addShortcut() { Shortcuts.addInteractively() }

    @objc private func curtainOff() { Curtain.shared.set(false) }
    @objc private func openHelp() { Self.open("help") }
    @objc private func reportProblem() { Self.open("issues") }

    static func open(_ link: String) {
        if let s = BuildInfo.links[link], let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLoginItem() { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func quit() { NSApp.terminate(nil) }
}
