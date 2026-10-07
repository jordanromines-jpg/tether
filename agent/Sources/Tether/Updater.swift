import Foundation
import TetherCore

/// "Update now": runs scripts/update.sh from this Mac's Tether source as a one-shot launchd job.
/// The job is separate from Tether, so it keeps going when the install restarts Tether; the new
/// copy picks up its progress from update.json and reports how it ended. Only a click in the
/// Mac's own panel starts it (never a connected device).
final class Updater {
    static let shared = Updater()
    var onChange: () -> Void = {}
    private(set) var progress: UpdateProgress?
    private var timer: Timer?
    private let label = "com.tether.updater"
    private var domain: String { "gui/\(getuid())" }
    private var statusURL: URL { AppPaths.supportDirectory.appendingPathComponent("update.json") }
    private var jobURL: URL { AppPaths.supportDirectory.appendingPathComponent("updater.plist") }
    static var logURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Tether-update.log") }

    /// Apple's developer tools present? Asked once; `xcode-select -p` is quick and never prompts.
    private lazy var hasTools: Bool = Self.run("/usr/bin/xcode-select", ["-p"]) == 0

    var mode: UpdateMode {
        let config = AppConfig.load()
        let fm = FileManager.default
        let isCheckout = config.sourceDir.map { fm.fileExists(atPath: $0 + "/.git") && fm.fileExists(atPath: $0 + "/scripts/update.sh") } ?? false
        return UpdateMode.decide(sourceDir: config.sourceDir, isCheckout: isCheckout, hasTools: hasTools, updateFrom: config.updateFrom)
    }

    var running: Bool { progress?.state == .running }

    /// At launch: follow an update that is still installing (it restarted Tether), or show how it ended.
    func resume() {
        guard let p = read() else { return }
        progress = p
        if p.state == .running {
            if jobLoaded { poll() } else { fail("The update was interrupted. Try again.") }
        } else {
            cleanUp()
            // An old result isn't news any more.
            if let at = p.at, Date().timeIntervalSince(at) > 86_400 { dismiss() }
        }
    }

    func start() {
        guard case .here(let source) = mode, !running else { return }
        Self.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        write(UpdateProgress(state: .running, step: "starting", message: "Starting", at: Date()))
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", source + "/scripts/update.sh", "--status-file", statusURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": Self.logURL.path,
            "StandardErrorPath": Self.logURL.path,
            "EnvironmentVariables": ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        try? FileManager.default.removeItem(at: Self.logURL)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: jobURL)) != nil,
              Self.run("/bin/launchctl", ["bootstrap", domain, jobURL.path]) == 0 else {
            fail("Couldn't start the update. See \(Self.logURL.path).")
            return
        }
        NSLog("Tether: update started from \(source)")
        poll()
    }

    /// Clears a finished result from the panel.
    func dismiss() {
        try? FileManager.default.removeItem(at: statusURL)
        progress = nil
        onChange()
    }

    private func poll() {
        timer?.invalidate()
        onChange()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let p = self.read() else { return }
            if p != self.progress { self.progress = p; self.onChange() }
            if p.finished { self.cleanUp() } else if !self.jobLoaded { self.fail("The update stopped. See \(Self.logURL.path).") }
        }
    }

    private func fail(_ message: String) {
        write(UpdateProgress(state: .failed, step: progress?.step ?? "", message: message, at: Date()))
        cleanUp()
    }

    private func cleanUp() {
        timer?.invalidate()
        timer = nil
        Self.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: jobURL)
        onChange()
    }

    private var jobLoaded: Bool { Self.run("/bin/launchctl", ["print", "\(domain)/\(label)"]) == 0 }

    private func read() -> UpdateProgress? { (try? Data(contentsOf: statusURL)).flatMap(UpdateProgress.parse) }

    private func write(_ p: UpdateProgress) {
        progress = p
        let o: [String: Any] = ["state": p.state.rawValue, "step": p.step, "message": p.message, "from": p.from, "to": p.to,
                                "at": ISO8601DateFormatter().string(from: p.at ?? Date())]
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: statusURL, options: .atomic) }
        onChange()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
