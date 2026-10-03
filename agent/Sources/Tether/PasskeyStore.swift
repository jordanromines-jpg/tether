import Foundation
import TetherCore

/// Persistent state for the optional passkey lock, in ~/Library/Application Support/Tether/.
/// New passkeys can only be enrolled during a short window opened from the Mac's menu bar,
/// so a stolen-but-signed-in device can't just register its own passkey.
final class PasskeyStore {
    static let shared = PasskeyStore()

    struct Credential: Codable {
        let id: String          // base64url credential ID
        let publicKey: String   // base64 SPKI (P-256)
        let login: String
        let device: String
        let created: Date
    }

    private struct Settings: Codable { var required = false }

    private let lock = NSLock()
    private let dir: URL
    private var settings = Settings()
    private(set) var credentials: [Credential] = []
    private var challenges: [String: (data: Data, expires: Date)] = [:]
    private(set) var enrollUntil: Date?
    let tokens: SessionToken

    static let cookieName = "tether_session"
    static let sessionLength: TimeInterval = 12 * 3600

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tether")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let secretURL = dir.appendingPathComponent("session-secret")
        var secret = (try? Data(contentsOf: secretURL)) ?? Data()
        if secret.count != 32 {
            secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            FileManager.default.createFile(atPath: secretURL.path, contents: secret, attributes: [.posixPermissions: 0o600])
        }
        tokens = SessionToken(secret: secret)
        if let d = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
           let s = try? JSONDecoder().decode(Settings.self, from: d) { settings = s }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("passkeys.json")),
           let c = try? JSONDecoder().decode([Credential].self, from: d) { credentials = c }
    }

    var required: Bool { lock.withLock { settings.required } }
    var enrolling: Bool { lock.withLock { (enrollUntil ?? .distantPast) > Date() } }

    func setRequired(_ on: Bool) {
        lock.withLock {
            settings.required = on
            if on && credentials.isEmpty { enrollUntil = Date().addingTimeInterval(600) }
            save()
        }
    }

    func openEnrollment(minutes: Double = 10) { lock.withLock { enrollUntil = Date().addingTimeInterval(minutes * 60) } }

    func removeAll() { lock.withLock { credentials.removeAll(); save() } }

    func credentials(for login: String) -> [Credential] {
        lock.withLock { credentials.filter { $0.login == login.lowercased() } }
    }

    func add(_ c: Credential) { lock.withLock { credentials.append(c); save() } }

    func newChallenge(for key: String) -> Data {
        let data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        lock.withLock { challenges[key] = (data, Date().addingTimeInterval(120)) }
        return data
    }

    /// Single use: the challenge is removed whether or not it's still valid.
    func takeChallenge(for key: String) -> Data? {
        lock.withLock {
            defer { challenges[key] = nil }
            guard let c = challenges[key], c.expires > Date() else { return nil }
            return c.data
        }
    }

    func sessionIsValid(cookieHeader: String?, login: String) -> Bool {
        guard let cookieHeader else { return false }
        for part in cookieHeader.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix(Self.cookieName + "="), tokens.isValid(String(kv.dropFirst(Self.cookieName.count + 1)), login: login) {
                return true
            }
        }
        return false
    }

    func sessionCookie(login: String) -> String {
        let token = tokens.issue(login: login, expires: Date().addingTimeInterval(Self.sessionLength))
        return "\(Self.cookieName)=\(token); Path=/; Max-Age=\(Int(Self.sessionLength)); HttpOnly; Secure; SameSite=Strict"
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? JSONEncoder().encode(settings) { try? d.write(to: dir.appendingPathComponent("settings.json")) }
        if let d = try? JSONEncoder().encode(credentials) {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("passkeys.json").path, contents: d,
                                           attributes: [.posixPermissions: 0o600])
        }
    }
}
