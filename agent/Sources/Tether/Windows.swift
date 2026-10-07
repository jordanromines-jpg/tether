import AppKit
import ApplicationServices
import ScreenCaptureKit
import TetherCore

/// The window switcher and single-window mode: list on-screen windows, bring one to the front,
/// read its frame, and resize it to a device's shape (restoring it afterwards).
enum WindowList {
    struct Info {
        let id: CGWindowID
        let title: String
        let app: String
        let bundleID: String
        let pid: pid_t
        let frame: CGRect
    }

    private static let iconLock = NSLock()
    nonisolated(unsafe) private static var icons: [String: String] = [:]

    static func list() async -> [Info] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let me = getpid()
        return content.windows.compactMap { w in
            guard w.windowLayer == 0, w.isOnScreen, let app = w.owningApplication, app.processID != me,
                  let title = w.title, !title.isEmpty, w.frame.width >= 120, w.frame.height >= 80 else { return nil }
            return Info(id: w.windowID, title: title, app: app.applicationName, bundleID: app.bundleIdentifier,
                        pid: app.processID, frame: w.frame)
        }
    }

    static func json(_ list: [Info]) -> [[String: Any]] {
        list.map { i in
            ["id": i.id, "title": i.title, "app": i.app, "bundle": i.bundleID, "icon": icon(pid: i.pid, bundle: i.bundleID),
             "x": Int(i.frame.minX), "y": Int(i.frame.minY), "w": Int(i.frame.width), "h": Int(i.frame.height)]
        }
    }

    /// A 32 pt app icon as PNG base64 (cached per app).
    private static func icon(pid: pid_t, bundle: String) -> String {
        if let cached = iconLock.withLock({ icons[bundle] }) { return cached }
        guard let image = NSRunningApplication(processIdentifier: pid)?.icon else { return "" }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let b64 = rep.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""
        iconLock.withLock { icons[bundle] = b64 }
        return b64
    }

    /// Current frame (global points, top-left origin) of a window, or nil if it closed.
    static func frame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) ?? true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    /// Brings the app forward and raises the matching window. Main thread.
    static func raise(_ info: Info) {
        NSRunningApplication(processIdentifier: info.pid)?.activate()
        guard let w = axWindow(for: info) else { return }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Resizes the window; returns false if it can't be resized. Main thread.
    @discardableResult
    static func resize(_ info: Info, to size: CGSize, origin: CGPoint? = nil) -> Bool {
        guard let w = axWindow(for: info) else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
        guard settable.boolValue else { return false }
        if let origin {
            var o = origin
            if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        }
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
    }

    /// Accessibility has no public window-ID lookup: match by title, then by closest frame.
    private static func axWindow(for info: Info) -> AXUIElement? {
        let app = AXUIElementCreateApplication(info.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }
        func frame(_ w: AXUIElement) -> CGRect {
            var p: CFTypeRef?, s: CFTypeRef?
            var pt = CGPoint.zero, sz = CGSize.zero
            if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success, let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success, let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
            return CGRect(origin: pt, size: sz)
        }
        func title(_ w: AXUIElement) -> String {
            var t: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success ? (t as? String ?? "") : ""
        }
        let titled = windows.filter { title($0) == info.title }
        let pool = titled.isEmpty ? windows : titled
        return pool.min { a, b in
            let fa = frame(a), fb = frame(b)
            return hypot(fa.midX - info.frame.midX, fa.midY - info.frame.midY) < hypot(fb.midX - info.frame.midX, fb.midY - info.frame.midY)
        }
    }
}
