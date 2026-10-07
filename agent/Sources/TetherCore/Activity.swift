import Foundation

/// One remote session, as shown in the menu-bar panel's Activity list.
public struct ActivityEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var login: String
    public var device: String
    public var start: Date
    public var end: Date?
    public var viewOnly: Bool

    public init(id: UUID, login: String, device: String, start: Date, end: Date? = nil, viewOnly: Bool = false) {
        self.id = id; self.login = login; self.device = device; self.start = start; self.end = end; self.viewOnly = viewOnly
    }

    /// "12 min", "1 h 5 min", "under a minute", or "now" while still connected.
    public func durationText(now: Date = Date()) -> String {
        guard let end else { return "now" }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// The last `limit` sessions, newest first. Stored as activity.json.
public struct ActivityLog: Equatable, Sendable {
    public private(set) var entries: [ActivityEntry]
    public let limit: Int

    public init(entries: [ActivityEntry] = [], limit: Int = 500) {
        self.entries = Array(entries.prefix(limit))
        self.limit = limit
    }

    public init(json: Data?, limit: Int = 500) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = json.flatMap { try? decoder.decode([ActivityEntry].self, from: $0) } ?? []
        self.init(entries: list, limit: limit)
    }

    public mutating func started(_ e: ActivityEntry) {
        entries.removeAll { $0.id == e.id }
        entries.insert(e, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func ended(id: UUID, at date: Date, viewOnly: Bool? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].end = date
        if let viewOnly { entries[i].viewOnly = entries[i].viewOnly || viewOnly }
    }

    /// Sessions left open by a crash or restart get an end time so they don't read as "now" forever.
    public mutating func closeDangling(at date: Date) {
        for i in entries.indices where entries[i].end == nil { entries[i].end = date }
    }

    public var json: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }
}

/// "Update available": is the newest commit on GitHub newer than the one this copy was built from?
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
}
