import Foundation
import TetherCore

/// Facts stamped into Info.plist by scripts/build-app.sh.
enum BuildInfo {
    /// "owner/name" of the GitHub repo this copy was built from (so forks link to themselves).
    static var repo: String { Bundle.main.object(forInfoDictionaryKey: "TetherRepo") as? String ?? Links.defaultRepo }

    /// When the commit this copy was built from was made (ISO 8601), if known.
    static var buildDate: Date? {
        (Bundle.main.object(forInfoDictionaryKey: "TetherBuildDate") as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// The full git commit this copy was built from, if known.
    static var commit: String? {
        (Bundle.main.object(forInfoDictionaryKey: "TetherCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Short form for display and for the web page's "was Tether updated?" check.
    static var version: String { commit.map { String($0.prefix(7)) } ?? "dev" }

    /// The version number from VERSION ("6.0"), stamped by build-app.sh. Nil in dev builds.
    static var release: String? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
    }

    /// For people: "6.0 (573e17e)", or just the commit when there's no version number.
    static var label: String { release.map { "\($0) (\(version))" } ?? version }

    static var links: [String: String] { Links.urls(repo: repo) }
}
