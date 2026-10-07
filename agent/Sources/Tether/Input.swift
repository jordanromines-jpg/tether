import CoreGraphics
import Foundation
import TetherCore

/// Injects mouse and keyboard events into macOS via CGEvent (needs Accessibility).
/// Not thread-safe: call from the hub queue only.
final class InputInjector {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    /// Set while streaming a single window: positions map to its frame instead of the display.
    var captureRect: CGRect?

    /// Every injected event carries TetherMarker in its user data (see the curtain's escape keys).
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = TetherMarker.eventUserData
        return s
    }()
    private var buttonsDown = Set<Int>()
    private var heldKeys = Set<UInt16>()
    private var heldModifiers = Set<UInt16>()
    private var capsLock = false
    private var lastClick: (time: TimeInterval, point: CGPoint, button: Int, count: Int64) = (0, .zero, -1, 0)

    private var bounds: CGRect { captureRect ?? CGDisplayBounds(displayID) }

    var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Cursor position normalized to the current display, or nil when it is on another display.
    var normalizedCursor: CGPoint? {
        let b = bounds, p = cursorLocation
        guard b.width > 0, b.height > 0, b.insetBy(dx: -1, dy: -1).contains(p) else { return nil }
        return CGPoint(x: (p.x - b.minX) / b.width, y: (p.y - b.minY) / b.height)
    }

    // MARK: Mouse

    func move(x: Double, y: Double) {
        let b = bounds
        postMove(to: CGPoint(x: b.minX + clamp01(x) * b.width, y: b.minY + clamp01(y) * b.height))
    }

    func moveRelative(dx: Double, dy: Double) {
        let b = bounds
        let p = cursorLocation
        let nx = min(max(p.x + dx * b.width, b.minX), b.maxX - 1)
        let ny = min(max(p.y + dy * b.height, b.minY), b.maxY - 1)
        postMove(to: CGPoint(x: nx, y: ny))
    }

    func button(_ index: Int, down: Bool) {
        let p = cursorLocation
        let (type, cgButton): (CGEventType, CGMouseButton) = switch index {
        case 2: (down ? .rightMouseDown : .rightMouseUp, .right)
        case 1: (down ? .otherMouseDown : .otherMouseUp, .center)
        default: (down ? .leftMouseDown : .leftMouseUp, .left)
        }
        if down {
            // Derive double/triple-click from timing so every client gets it for free.
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(p.x - lastClick.point.x, p.y - lastClick.point.y) < 6
            let count: Int64 = (now - lastClick.time < 0.45 && near && lastClick.button == index) ? lastClick.count + 1 : 1
            lastClick = (now, p, index, count)
            buttonsDown.insert(index)
        } else {
            buttonsDown.remove(index)
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: lastClick.count)
        e.flags = currentFlags
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(clamping: Int(-dy.rounded())), wheel2: Int32(clamping: Int(-dx.rounded())), wheel3: 0) else { return }
        e.flags = currentFlags
        e.post(tap: .cghidEventTap)
    }

    private func postMove(to p: CGPoint) {
        let (type, button): (CGEventType, CGMouseButton) =
            buttonsDown.contains(0) ? (.leftMouseDragged, .left)
            : buttonsDown.contains(2) ? (.rightMouseDragged, .right)
            : buttonsDown.contains(1) ? (.otherMouseDragged, .center)
            : (.mouseMoved, .left)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = currentFlags
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    func key(code: String, down: Bool) {
        guard let vk = KeyMap.keycode(for: code) else { return }
        if let mod = KeyMap.modifier(forKeycode: vk) {
            if mod == .capsLock {
                if down { capsLock.toggle() }
            } else if down {
                heldModifiers.insert(vk)
            } else {
                heldModifiers.remove(vk)
            }
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = currentFlags
            e.post(tap: .cghidEventTap)
            return
        }
        if down { heldKeys.insert(vk) } else { heldKeys.remove(vk) }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
        var flags = currentFlags
        if (0x7B...0x7E).contains(vk) { flags.insert([.maskNumericPad, .maskSecondaryFn]) }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// Types arbitrary Unicode text (used by phone/tablet soft keyboards).
    func type(text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += 16
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Releases everything a disconnected client may have left held down.
    func releaseAll() {
        for b in buttonsDown { button(b, down: false) }
        for vk in heldKeys {
            CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false)?.post(tap: .cghidEventTap)
        }
        heldKeys.removeAll()
        let mods = heldModifiers
        heldModifiers.removeAll()
        for vk in mods {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false) else { continue }
            e.type = .flagsChanged
            e.flags = currentFlags
            e.post(tap: .cghidEventTap)
        }
    }

    private var currentFlags: CGEventFlags {
        var f: CGEventFlags = []
        for vk in heldModifiers {
            switch KeyMap.modifier(forKeycode: vk) {
            case .command: f.insert(.maskCommand)
            case .shift: f.insert(.maskShift)
            case .option: f.insert(.maskAlternate)
            case .control: f.insert(.maskControl)
            case .function: f.insert(.maskSecondaryFn)
            default: break
            }
        }
        if capsLock { f.insert(.maskAlphaShift) }
        return f
    }

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
