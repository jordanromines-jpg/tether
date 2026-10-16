import AppKit
import Foundation
import Sparkle
import TetherCore

/// Updates for a download from GitHub Releases, through Sparkle. Sparkle checks the feed once a day and
/// downloads a newer release quietly; it is only installed (which restarts Tether) while no device is
/// connected, or when someone clicks Install now in the Mac's own panel. Only an update signed with the
/// update key in Info.plist (SUPublicEDKey) is accepted. Source builds never start this.
final class ReleaseUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = ReleaseUpdater()

    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        /// Downloaded and waiting for nobody to be connected.
        case ready(version: String)
        case installing(version: String)
        case failed(String)
    }

    var onChange: () -> Void = {}
    private(set) var state: State = .idle
    private(set) var whatsNew: [String] = []
    private var updater: SPUUpdater?
    private var installNow: (() -> Void)?
    private var connectedDevices = 0

    /// SUFeedURL from Info.plist; only release builds (scripts/build-app.sh --release) have one.
    static var feedURL: String? { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }

    func start() {
        guard updater == nil, Self.feedURL != nil else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                           userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: self)
        do {
            try u.start()
        } catch {
            NSLog("Tether: Sparkle couldn't start: \(error.localizedDescription)")
            set(.failed("Couldn't start the updater: \(error.localizedDescription)"))
            return
        }
        u.automaticallyDownloadsUpdates = true
        u.automaticallyChecksForUpdates = AppState.shared.checkUpdates
        updater = u
        NSLog("Tether: Sparkle started, feed \(Self.feedURL ?? "")")
    }

    /// The "Check for updates" setting in the panel.
    func setChecks(_ on: Bool) { updater?.automaticallyChecksForUpdates = on }

    /// A quiet check (no windows), for the panel's daily check.
    func checkInBackground() {
        guard let updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Install now or Update now, clicked on the Mac: install a downloaded update straight away
    /// (connected devices reconnect by themselves), or check and show Sparkle's own window.
    func installOrCheck() {
        if installNow != nil { install(askedOnMac: true); return }
        updater?.checkForUpdates()
    }

    /// Hub's connected devices changed: an update waiting for an empty Mac installs now.
    func devicesChanged(_ count: Int) {
        connectedDevices = count
        if installNow != nil { install(askedOnMac: false) }
    }

    /// Clears a failure from the panel (Dismiss).
    func dismiss() {
        if case .failed = state { set(.idle) }
    }

    private func install(askedOnMac: Bool) {
        guard ReleaseInstall.shouldInstall(updateReady: installNow != nil, connectedDevices: connectedDevices, askedOnMac: askedOnMac),
              let go = installNow, case .ready(let version) = state else { return }
        installNow = nil
        NSLog("Tether: Sparkle installing \(version) (\(askedOnMac ? "asked on the Mac" : "nobody connected"))")
        set(.installing(version: version))
        Updater.shared.recordReleaseInstall(to: version, whatsNew: whatsNew)
        go()
    }

    private func set(_ s: State) {
        DispatchQueue.main.async {
            self.state = s
            self.onChange()
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Tether: Sparkle found \(item.displayVersionString) (\(item.versionString))")
        whatsNew = ReleaseInstall.whatsNew(item.itemDescription)
        set(.downloading(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NSLog("Tether: Sparkle checked the feed: up to date")
        if case .checking = state { set(.idle) }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        NSLog("Tether: Sparkle downloaded \(item.displayVersionString)")
    }

    /// Sparkle would install on quit; take the block instead and use it when nobody is connected.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async {
            self.installNow = immediateInstallHandler
            self.state = .ready(version: item.displayVersionString)
            self.onChange()
            NSLog("Tether: Sparkle has \(item.displayVersionString) ready; installs when nobody is connected")
            self.install(askedOnMac: false)
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // "No update found" also arrives here; it isn't a failure.
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { set(.idle); return }
        NSLog("Tether: Sparkle error: \(error.localizedDescription)")
        set(.failed(error.localizedDescription))
    }
}
