import AppKit
import SwiftUI
import TetherCore
import TetherUI

/// Curtain mode: a black window over every screen of this Mac, so people in the room can't see
/// what the remote person is doing. Tether leaves these windows out of the stream, and clicks
/// pass through them (they ignore the mouse). It hides the screen; it is not access control:
/// the Mac's own keyboard and mouse keep working, and ⌃⌥⌘ Return lifts it.
final class Curtain {
    static let shared = Curtain()

    /// Called on the main thread with the new state and the window IDs to exclude from capture.
    var onChange: ((Bool, [CGWindowID]) -> Void)?

    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var screenObserver: Any?
    private let lock = NSLock()
    private var ids: [CGWindowID] = []

    var isOn: Bool { !windows.isEmpty }
    /// Readable from any thread.
    var isOnApprox: Bool { lock.withLock { !ids.isEmpty } }

    /// Main thread only.
    func set(_ on: Bool) {
        guard on != isOn else { return }
        if on { build() } else { tearDown() }
        let current = windows.map { CGWindowID($0.windowNumber) }
        lock.withLock { ids = current }
        onChange?(on, current)
    }

    private func build() {
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.isOpaque = true
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: CurtainView())
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        // ⌃⌥⌘ Return on this Mac's own keyboard lifts the curtain. Keys Tether injects carry
        // TetherMarker, so the remote person can't lift it by accident (they use the toggle).
        let handler: (NSEvent) -> Void = { [weak self] e in
            let mods = e.modifierFlags.intersection([.control, .option, .command, .shift])
            guard e.keyCode == 36, mods == [.control, .option, .command],
                  !TetherMarker.isRemote(eventUserData: e.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
            else { return }
            DispatchQueue.main.async { self?.set(false) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { monitors.append(m) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isOn else { return }
            self.tearDown()
            self.build()
            let current = self.windows.map { CGWindowID($0.windowNumber) }
            self.lock.withLock { self.ids = current }
            self.onChange?(true, current)
        }
    }

    private func tearDown() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
    }

    /// For /healthz: is the curtain really on screen, covering every display?
    func status() -> [String: Any] {
        let mine = lock.withLock { ids }
        guard !mine.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ["on": false, "windows": 0, "screensCovered": 0]
        }
        let shown = info.filter { ($0[kCGWindowNumber as String] as? Int).map { mine.contains(CGWindowID($0)) } ?? false }
        let rects = shown.compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &count)
        let covered = displays.prefix(Int(count)).filter { d in rects.contains { $0.contains(CGDisplayBounds(d)) } }.count
        return ["on": true, "windows": shown.count, "screensCovered": covered, "screens": Int(count)]
    }
}
