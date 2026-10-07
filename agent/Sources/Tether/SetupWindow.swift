import AppKit
import SwiftUI
import TetherCore
import TetherUI

/// The Setup Assistant window. Opens on first launch, when a permission is missing, or on
/// tether://setup (which scripts/setup.sh uses); reopen it any time from the menu-bar panel.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let model = SetupModel()
    private var timer: Timer?
    private var checkingNetwork = false
    /// Set once the person chooses Keep open, so the window stops trying to close itself.
    private var keepOpen = false
    var onFinish: () -> Void = {}

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set up Tether"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupAssistantView(model: model))
        window.center()
        wire()
    }

    private func wire() {
        model.loginItemInstalled = LoginItem.isInstalled
        model.startAtLogin = LoginItem.isInstalled ? LoginItem.isEnabled : false
        model.tailscaleInstalled = Peers.tailscalePath != nil
        var a = SetupActions()
        a.openScreenRecording = { Permissions.requestMissing(); Self.openPrivacy("Privacy_ScreenCapture") }
        a.openAccessibility = { Permissions.requestMissing(); Self.openPrivacy("Privacy_Accessibility") }
        a.revealApp = { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
        a.openTailscale = {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
        }
        a.openTailscaleDownload = { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
        a.openAdminDNS = { NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/dns")!) }
        a.copy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        a.chooseFolder = { Shortcuts.chooseFolder() }
        a.finish = { [weak self] in self?.finish() }
        a.openHelp = { AppDelegate.open("help") }
        a.keepOpen = { [weak self] in self?.keepOpen = true; self?.model.closingIn = nil }
        model.actions = a
    }

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func show(step: SetupStep? = nil) {
        if let step { model.step = step }
        else if !AppState.shared.onboarded { model.step = .welcome }
        else if !(Permissions.screenRecording && Permissions.accessibility) { model.step = .permissions }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Live checkmarks: permissions every second, Tailscale every few seconds (it runs the CLI).
    private func refresh() {
        model.screenAllowed = Permissions.screenRecording
        model.inputAllowed = Permissions.accessibility
        countDownIfComplete()
        guard !checkingNetwork else { return }
        checkingNetwork = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Peers.tailnetStatus()
            Thread.sleep(forTimeInterval: 2)
            DispatchQueue.main.async {
                self?.model.tailnet = status
                self?.model.tailscaleInstalled = Peers.tailscalePath != nil
                self?.checkingNetwork = false
            }
        }
    }

    private func finish() {
        if model.loginItemInstalled, model.startAtLogin != LoginItem.isEnabled { LoginItem.setEnabled(model.startAtLogin) }
        if model.addShortcut {
            do { try Shortcuts.addAlias(in: model.shortcutFolder) } catch {
                NSAlert(error: error).beginSheetModal(for: window!) { _ in }
                return
            }
        }
        AppState.shared.setOnboarded()
        close()
        onFinish()
    }

    /// Everything done and a device has connected: show "All set" and close in 5 seconds, keeping
    /// the person's current choices (no new shortcut, login item unchanged). Runs once a second.
    private func countDownIfComplete() {
        guard !keepOpen, window?.isVisible == true, isComplete else { model.closingIn = nil; return }
        if model.step != .done { model.step = .done }
        let left = (model.closingIn ?? 6) - 1
        if left > 0 { model.closingIn = left; return }
        model.closingIn = nil
        AppState.shared.setOnboarded()
        close()
        onFinish()
    }

    private var isComplete: Bool {
        let deviceConnected = Hub.shared.queue.sync { !Hub.shared.clients.isEmpty } || !ActivityStore.shared.recent.isEmpty
        return SetupPolicy.isComplete(screenAllowed: model.screenAllowed, inputAllowed: model.inputAllowed,
                                      tailnet: model.tailnet == .unavailable ? nil : model.tailnet, deviceConnected: deviceConnected)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        model.closingIn = nil
        // Closing it with everything done counts as finishing.
        if isComplete { AppState.shared.setOnboarded() }
    }
}
