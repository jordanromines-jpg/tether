import AppKit

/// Tether's menu-bar glyph: a small display with the pointer from the app icon. It's a template
/// image, so macOS tints it for light, dark and highlighted menu bars.
public enum MenuBarIcon {
    public enum State { case idle, connected, paused }

    public static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let screen = NSRect(x: 2.25, y: 4.75, width: 15.5, height: 10.5)
            let outline = NSBezierPath(roundedRect: screen, xRadius: 2.25, yRadius: 2.25)
            outline.lineWidth = 1.5
            // Stand.
            NSBezierPath(roundedRect: NSRect(x: 9.25, y: 2, width: 1.5, height: 2.75), xRadius: 0.5, yRadius: 0.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: 1, width: 7, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()

            switch state {
            case .idle:
                outline.stroke()
                pointer(at: NSPoint(x: 8, y: 13)).fill()
            case .connected:
                // Solid screen with the pointer knocked out: "someone is looking at this Mac".
                outline.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                pointer(at: NSPoint(x: 8, y: 13)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .paused:
                outline.stroke()
                NSBezierPath(roundedRect: NSRect(x: 7.6, y: 7.25, width: 1.6, height: 5.5), xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(roundedRect: NSRect(x: 10.8, y: 7.25, width: 1.6, height: 5.5), xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch state {
        case .idle: "Tether"
        case .connected: "Tether, connected"
        case .paused: "Tether, paused"
        }
        return image
    }

    /// The arrow pointer from the app icon, tip at `tip`, about 4.7 × 7 points.
    private static func pointer(at tip: NSPoint) -> NSBezierPath {
        let p = NSBezierPath()
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -6.6), (1.6, -5.1), (2.7, -7.3), (3.9, -6.8), (2.8, -4.6), (4.9, -4.6)]
        for (i, pt) in pts.enumerated() {
            let q = NSPoint(x: tip.x + pt.0, y: tip.y + pt.1)
            if i == 0 { p.move(to: q) } else { p.line(to: q) }
        }
        p.close()
        return p
    }
}
