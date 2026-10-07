import CoreGraphics

/// Maps between normalized stream coordinates (0…1 across what's being streamed) and global
/// screen points, for a whole display or a single window anywhere on any display.
public enum WindowGeometry {
    /// Normalized (x, y) inside `rect` → global point, clamped inside the rect.
    public static func toGlobal(x: Double, y: Double, in rect: CGRect) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: rect.minX + cx * rect.width, y: rect.minY + cy * rect.height)
    }

    /// Global point → normalized inside `rect`, or nil when it's outside (with 1 pt slack).
    public static func toNormalized(_ p: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.insetBy(dx: -1, dy: -1).contains(p) else { return nil }
        return CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
    }

    /// Moves a point by a normalized delta, keeping it inside `rect`.
    public static func moveBy(_ p: CGPoint, dx: Double, dy: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x + dx * rect.width, rect.minX), rect.maxX - 1),
                y: min(max(p.y + dy * rect.height, rect.minY), rect.maxY - 1))
    }

    /// Whether a window's size changed enough (over 2%) that capture should restart at the new size.
    public static func sizeChanged(_ a: CGRect, _ b: CGRect) -> Bool {
        guard a.width > 0, a.height > 0 else { return true }
        return abs(b.width - a.width) / a.width > 0.02 || abs(b.height - a.height) / a.height > 0.02
    }

    /// The size for "Fit to this device": the window keeps its area roughly but takes the
    /// device's aspect ratio, never larger than the screen it's on.
    public static func fitSize(window: CGSize, aspect: Double, screen: CGSize) -> CGSize {
        guard aspect > 0 else { return window }
        let area = max(window.width * window.height, 400 * 300)
        var h = (area / aspect).squareRoot()
        var w = h * aspect
        let scale = min(1, screen.width / w, screen.height / h)
        w *= scale; h *= scale
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}
