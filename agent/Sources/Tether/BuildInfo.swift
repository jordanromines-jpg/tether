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

    static var links: [String: String] { Links.urls(repo: repo) }
}
