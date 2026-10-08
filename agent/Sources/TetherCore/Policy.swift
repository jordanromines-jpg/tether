import Foundation

/// One-tap Mac controls from the Quick actions sheet.
public enum QuickAction: String, CaseIterable, Sendable {
    case volumeUp, volumeDown, mute, playPause, next, previous, lockScreen, sleepDisplay, missionControl, forceQuit

    /// NX_KEYTYPE_* code for actions sent as media keys; nil for the others.
    public var mediaKey: Int? {
        switch self {
        case .volumeUp: 0          // NX_KEYTYPE_SOUND_UP
        case .volumeDown: 1        // NX_KEYTYPE_SOUND_DOWN
        case .mute: 7              // NX_KEYTYPE_MUTE
        case .playPause: 16        // NX_KEYTYPE_PLAY
        case .next: 17             // NX_KEYTYPE_NEXT
        case .previous: 18         // NX_KEYTYPE_PREVIOUS
        default: nil
        }
    }

    /// Key combos (KeyboardEvent.code names) for actions sent as shortcuts.
    public var combo: [String]? {
        switch self {
        case .lockScreen: ["ControlLeft", "MetaLeft", "KeyQ"]
        case .missionControl: ["ControlLeft", "ArrowUp"]
        case .forceQuit: ["MetaLeft", "AltLeft", "Escape"]
        default: nil
        }
    }
}

public enum InputPolicy {
    /// Messages that act on the Mac. View-only clients may not send them, and they're what
    /// counts as "someone is using this" for idle tracking.
    public static func isControl(_ m: ClientMessage) -> Bool {
        switch m {
        case .move, .moveRelative, .button, .scroll, .key, .text, .releaseAll, .setClipboard,
             .action, .openURL, .openApp, .focusWindow, .captureWindow, .curtain, .wake:
            return true
        case .hello, .quality, .display, .keyframe, .ping, .audio, .fit, .stats, .observe, .windows, .activity:
            return false
        }
    }

    /// Whether a message counts as someone using the session (for "idle 12 min").
    public static func isActivity(_ m: ClientMessage) -> Bool {
        if case .activity = m { return true }
        return isControl(m)
    }
}

public enum SafeURL {
    /// Only http(s) links with a host, at most 4096 characters, may be opened on the Mac.
    public static func validate(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 4096, let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// Where help lives. The repo comes from the build (TetherRepo in Info.plist), so forks point at themselves.
public enum Links {
    public static let defaultRepo = "jordanromines-jpg/tether"

    /// "owner/name" from a git remote URL (https or ssh form), or nil.
    public static func repo(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        guard let r = s.range(of: "github.com[:/]", options: .regularExpression) else { return nil }
        let parts = s[r.upperBound...].split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    public static func urls(repo: String) -> [String: String] {
        let base = "https://github.com/\(repo)"
        return ["repo": base, "help": "\(base)#using-it", "issues": "\(base)/issues/new", "updating": "\(base)#updating"]
    }
}

/// Every event Tether injects carries this value in its event-source user data, so code that
/// watches the keyboard (the curtain's escape keys) can tell remote keys from the Mac's own.
public enum TetherMarker {
    public static let eventUserData: Int64 = 0x7E7_4E52   // "~tNR"
    public static func isRemote(eventUserData: Int64) -> Bool { eventUserData == Self.eventUserData }
}

/// Where a relative (trackpad) move starts from. macOS reports the pointer's location a step behind
/// while moves are still arriving, so adding a move to that reading drops the moves in between: the
/// Mac's pointer then travels less than the one drawn on the phone, and clicks land short of it.
/// Right after Tether moved the pointer, start from where Tether put it instead.
public enum PointerBase {
    public static let trustPostedFor: TimeInterval = 0.5

    public static func choose(posted: CGPoint?, postedAt: TimeInterval, now: TimeInterval, system: CGPoint) -> CGPoint {
        guard let posted, now - postedAt < trustPostedFor else { return system }
        return posted
    }
}

/// Why there's no picture, in plain words, for the device that's waiting for one.
public enum CaptureProblem {
    public struct Reason: Equatable, Sendable {
        public let kind: String, title: String, message: String
    }

    public static func reason(screenRecording: Bool, lidClosed: Bool, asleep: Bool, error: String) -> Reason {
        if !screenRecording {
            return Reason(kind: "permission", title: "Screen Recording is off",
                          message: "On the Mac, allow Tether in Privacy & Security → Screen Recording.")
        }
        if lidClosed {
            return Reason(kind: "lidClosed", title: "The lid is closed",
                          message: "A closed MacBook has no screen to show. Open the lid, or connect a display.")
        }
        if asleep {
            return Reason(kind: "asleep", title: "The display is asleep",
                          message: "Tether is waking it. The picture appears as soon as it's on.")
        }
        return Reason(kind: "capture", title: "Can't show the screen", message: "Couldn't start screen capture: \(error)")
    }
}
