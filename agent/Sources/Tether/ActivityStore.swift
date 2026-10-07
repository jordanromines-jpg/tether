import Foundation
import TetherCore

/// Who connected, from which device, when and for how long. Kept in activity.json (last 500).
final class ActivityStore {
    static let shared = ActivityStore()
    var onChange: () -> Void = {}
    private let lock = NSLock()
    private var log: ActivityLog
    private var url: URL { AppPaths.supportDirectory.appendingPathComponent("activity.json") }

    private init() {
        log = ActivityLog(json: try? Data(contentsOf: AppPaths.supportDirectory.appendingPathComponent("activity.json")))
        log.closeDangling(at: Date())   // sessions open when Tether last stopped
        save()
    }

    var recent: [ActivityEntry] { lock.withLock { log.entries } }

    func started(_ c: ClientConnection) {
        lock.withLock {
            log.started(ActivityEntry(id: c.id, login: c.login, device: c.device, start: c.connectedAt, viewOnly: c.observe))
            save()
        }
        DispatchQueue.main.async { self.onChange() }
    }

    func ended(_ c: ClientConnection) {
        lock.withLock { log.ended(id: c.id, at: Date(), viewOnly: c.observe); save() }
        DispatchQueue.main.async { self.onChange() }
    }

    /// Call with the lock held.
    private func save() {
        FileManager.default.createFile(atPath: url.path, contents: log.json, attributes: [.posixPermissions: 0o600])
    }
}
