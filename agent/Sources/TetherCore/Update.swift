import Foundation

/// "Update available": is there something newer on GitHub than the commit this copy was built from?
public enum UpdateCheck {
    /// The committer date from GitHub's GET /repos/{owner}/{repo}/commits/{branch} response.
    public static func latestCommitDate(_ data: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = obj["commit"] as? [String: Any],
              let committer = commit["committer"] as? [String: Any],
              let date = committer["date"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: date)
    }

    /// Only a strictly newer commit counts, so a build of the latest (or of local changes) never nags.
    public static func isNewer(remote: Date?, build: Date?) -> Bool {
        guard let remote, let build else { return false }
        return remote.timeIntervalSince(build) > 60
    }

    /// What's new, from GitHub's GET /repos/{owner}/{repo}/compare/{build commit}...main response.
    /// "ahead" means main has commits this build lacks; "diverged" means this build also has commits
    /// of its own (an update would refuse, but there is still something newer to tell about).
    public static func compare(_ data: Data, limit: Int = 5) -> UpdateInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { return nil }
        let ahead = obj["ahead_by"] as? Int ?? 0
        let subjects = (obj["commits"] as? [[String: Any]] ?? []).compactMap { c -> String? in
            ((c["commit"] as? [String: Any])?["message"] as? String)?
                .split(separator: "\n", maxSplits: 1).first.map { String($0) }
        }
        // GitHub lists oldest first; show the newest first.
        return UpdateInfo(available: (status == "ahead" || status == "diverged") && ahead > 0,
                          count: ahead, whatsNew: Array(subjects.reversed().prefix(limit)))
    }
}

public struct UpdateInfo: Equatable {
    public let available: Bool
    public let count: Int
    public let whatsNew: [String]
    public init(available: Bool, count: Int, whatsNew: [String]) {
        self.available = available
        self.count = count
        self.whatsNew = whatsNew
    }
}

/// Where an update for this Mac comes from.
public enum UpdateMode: Equatable {
    /// This Mac has the source and the developer tools: "Update now" rebuilds it here.
    case here(sourceDir: String)
    /// Another Mac builds and installs it (named in the banner).
    case elsewhere(String)
    /// Unknown (an install from before updates were recorded): point to the instructions.
    case manual

    public static func decide(sourceDir: String?, isCheckout: Bool, hasTools: Bool, updateFrom: String?) -> UpdateMode {
        if let sourceDir, !sourceDir.isEmpty, isCheckout, hasTools { return .here(sourceDir: sourceDir) }
        if let updateFrom, !updateFrom.isEmpty { return .elsewhere(updateFrom) }
        return .manual
    }
}

/// Progress written by scripts/update.sh --status-file.
public struct UpdateProgress: Equatable {
    public enum State: String { case running, current, done, failed }
    public let state: State
    public let step: String
    public let message: String
    public let from: String
    public let to: String
    public let at: Date?

    public var finished: Bool { state != .running }

    public init(state: State, step: String, message: String, from: String = "", to: String = "", at: Date? = nil) {
        self.state = state
        self.step = step
        self.message = message
        self.from = from
        self.to = to
        self.at = at
    }

    public static func parse(_ data: Data) -> UpdateProgress? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = (o["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        let at = (o["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return UpdateProgress(state: state, step: o["step"] as? String ?? "", message: o["message"] as? String ?? "",
                              from: o["from"] as? String ?? "", to: o["to"] as? String ?? "", at: at)
    }
}
