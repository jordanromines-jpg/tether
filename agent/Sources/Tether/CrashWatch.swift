import Foundation
import TetherCore

/// Notices when Tether crashed since it last ran (macOS writes Tether-*.ips reports), tells the
/// person once, and offers a pre-filled GitHub issue. Nothing is sent automatically.
final class CrashWatch {
    static let shared = CrashWatch()
    var onChange: () -> Void = {}
    private(set) var latest: CrashSummary?
    private let seenKey = "crashReportsSeen"

    private var reportsFolder: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports") }

    /// At launch. The very first run only records what's already there, so old crashes don't nag.
    func check() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: reportsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Tether-") && $0.pathExtension == "ips" }
        let names = files.map(\.lastPathComponent)
        guard let seen = UserDefaults.standard.stringArray(forKey: seenKey) else {
            UserDefaults.standard.set(names, forKey: seenKey)
            return
        }
        let fresh = files.filter { !seen.contains($0.lastPathComponent) }
            .sorted { modified($0) > modified($1) }
        UserDefaults.standard.set(Array(Set(seen + names)), forKey: seenKey)
        guard let newest = fresh.first, let data = try? Data(contentsOf: newest), let summary = CrashSummary.parse(data) else { return }
        latest = summary
        NSLog("Tether: found a crash report from \(summary.date.map { "\($0)" } ?? "earlier"): \(summary.exception)")
        Notifier.crashed(at: summary.date)
        onChange()
    }

    func dismiss() {
        latest = nil
        onChange()
    }

    /// A GitHub "new issue" page with the summary filled in, for the person to read and submit.
    var issueURL: URL? {
        guard let latest, var c = URLComponents(string: BuildInfo.links["issues"] ?? "") else { return nil }
        c.queryItems = [URLQueryItem(name: "title", value: "Tether quit unexpectedly (\(latest.exception))"),
                        URLQueryItem(name: "body", value: latest.issueBody(version: BuildInfo.version))]
        return c.url
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
