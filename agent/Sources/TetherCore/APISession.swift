import Foundation

/// What the Allow Claude switch allows on a Mac (P-3 D-6, Q-1).
public enum APIAccess: String, Codable, CaseIterable, Sendable {
    case off       // every /api route answers 403
    case view      // screenshots and lists, no input
    case control   // input too

    /// Whether a message from Claude's API client may act on the Mac.
    public func allows(_ message: ClientMessage) -> Bool {
        self == .control || !InputPolicy.isControl(message)
    }

    /// The messages an API client may send at all. Nothing that changes what the web page's
    /// stream shows (display, window, fit, quality), turns view only off, or touches the curtain.
    public static func isAPIMessage(_ message: ClientMessage) -> Bool {
        switch message {
        case .move, .button, .scroll, .key, .text, .releaseAll, .openURL, .openApp, .focusWindow, .action:
            return true
        case .hello, .quality, .display, .keyframe, .moveRelative, .setClipboard, .ping, .audio, .wake, .fit, .stats,
             .observe, .curtain, .windows, .captureWindow, .activity:
            return false
        }
    }
}

/// The API clients in the Hub: one per calling device, reused between calls, dropped after
/// `idleSeconds` without a call. Pure bookkeeping; the Hub owns the clients themselves.
public struct APISessionTable: Sendable {
    /// API_IDLE_SECONDS: how long an API client lives without a call.
    public static let idleSeconds: TimeInterval = 120

    public let idleSeconds: TimeInterval
    public private(set) var lastCall: [String: Date] = [:]

    public init(idleSeconds: TimeInterval = APISessionTable.idleSeconds) { self.idleSeconds = idleSeconds }

    /// The key for a calling device: the Tailscale login plus the device name it sends.
    public static func key(login: String, device: String) -> String { login.lowercased() + "\n" + device }

    /// Records a call. Returns true when this device had no live client (so the Hub adds one).
    @discardableResult
    public mutating func touch(_ key: String, now: Date = Date()) -> Bool {
        let isNew = lastCall[key] == nil
        lastCall[key] = now
        return isNew
    }

    /// Removes and returns the keys idle for `idleSeconds` or more.
    public mutating func expire(now: Date = Date()) -> [String] {
        let old = lastCall.filter { now.timeIntervalSince($0.value) >= idleSeconds }.map(\.key).sorted()
        for k in old { lastCall[k] = nil }
        return old
    }

    public mutating func remove(_ key: String) { lastCall[key] = nil }

    public var keys: [String] { lastCall.keys.sorted() }
}
