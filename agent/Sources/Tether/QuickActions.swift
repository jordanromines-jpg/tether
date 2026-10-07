import AppKit
import TetherCore

/// The Quick actions sheet's Mac side: media keys and display sleep. (Shortcut-style actions
/// like Mission Control go through InputInjector as key combos.)
enum QuickActions {
    /// Presses and releases a media key (volume, play/pause…) the way the keyboard's own keys do.
    static func media(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1),
                  let cg = event.cgEvent else { continue }
            cg.setIntegerValueField(.eventSourceUserData, value: TetherMarker.eventUserData)
            cg.post(tap: .cghidEventTap)
        }
    }

    static func sleepDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

/// Apps that "Open an app by name" may launch: .app bundles in the standard Applications folders.
/// Only paths from this list are ever opened.
enum AppCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (at: Date, apps: [[String: String]])?

    static func list() -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < 300 { return cache.apps }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var apps: [[String: String]] = []
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(name)
                let display = (fm.displayName(atPath: path) as NSString).deletingPathExtension
                guard !seen.contains(display) else { continue }
                seen.insert(display)
                apps.append(["name": display, "path": path])
            }
        }
        apps.sort { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
        cache = (Date(), apps)
        return apps
    }

    static func contains(_ path: String) -> Bool { list().contains { $0["path"] == path } }
}
