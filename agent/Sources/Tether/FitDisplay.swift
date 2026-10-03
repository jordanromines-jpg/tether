import CoreGraphics
import Foundation
import VirtualDisplayShim

/// "Fit to device": a virtual display shaped like the client's screen.
///  - mirror: the Mac's main display mirrors it, so the whole desktop takes the device's shape.
///  - extend: it's an extra display the client sees on its own (drag windows onto it).
/// Everything is undone when stopped or when the app exits (the virtual display dies with the process).
final class FitDisplay {
    enum Mode: String { case off, mirror, extend }

    static var isAvailable: Bool { TetherVirtualDisplay.isAvailable() }

    private var virtual: TetherVirtualDisplay?
    private var mirroredDisplay: CGDirectDisplayID?
    private(set) var mode: Mode = .off

    var displayID: CGDirectDisplayID? { virtual?.displayID }

    /// Readable desktop size (points) for a client viewport: same shape, never cramped.
    static func pointsFor(viewportWidth w: Double, height h: Double) -> (UInt32, UInt32) {
        guard w > 0, h > 0 else { return (1440, 900) }
        let factor = max(1, 720 / min(w, h))           // short side at least 720 pt
        var pw = w * factor, ph = h * factor
        let cap = 2560.0 / max(pw, ph)                 // long side at most 2560 pt
        if cap < 1 { pw *= cap; ph *= cap }
        return (UInt32(pw) & ~1, UInt32(ph) & ~1)
    }

    /// Must be called on the main thread. Returns the display to capture, or nil on failure.
    func start(mode: Mode, viewportWidth: Double, viewportHeight: Double) -> CGDirectDisplayID? {
        stop()
        guard mode != .off, Self.isAvailable else { return nil }
        let (pw, ph) = Self.pointsFor(viewportWidth: viewportWidth, height: viewportHeight)
        guard let v = TetherVirtualDisplay(name: "Tether", pointsWide: pw, pointsHigh: ph), v.displayID != 0 else {
            NSLog("Tether: couldn't create virtual display")
            return nil
        }
        virtual = v
        self.mode = mode
        if mode == .mirror {
            let main = CGMainDisplayID()
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                CGConfigureDisplayMirrorOfDisplay(config, main, v.displayID)
                if CGCompleteDisplayConfiguration(config, .forSession) == .success {
                    mirroredDisplay = main
                } else {
                    NSLog("Tether: mirroring failed; falling back to extra display")
                    self.mode = .extend
                }
            }
        }
        NSLog("Tether: fit-to-device \(self.mode.rawValue) at \(pw)×\(ph) pt (display \(v.displayID))")
        return v.displayID
    }

    /// Must be called on the main thread.
    func stop() {
        if let physical = mirroredDisplay {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                CGConfigureDisplayMirrorOfDisplay(config, physical, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(config, .forSession)
            }
            mirroredDisplay = nil
        }
        virtual = nil
        mode = .off
    }
}
