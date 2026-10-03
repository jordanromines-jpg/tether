import AppKit

/// Watches the system cursor's shape so clients can draw it locally.
final class CursorWatcher {
    struct Shape {
        let pngBase64: String
        let widthPoints: Double
        let heightPoints: Double
        let hotX: Double
        let hotY: Double
    }

    var onChange: ((Shape) -> Void)?
    private(set) var current: Shape?
    private var timer: Timer?
    private var lastSignature: Data?

    func start() {
        DispatchQueue.main.async {
            guard self.timer == nil else { return }
            self.lastSignature = nil
            self.poll()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.poll() }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        // Render at 2x for crisp display on Retina clients.
        let px = NSSize(width: size.width * 2, height: size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        var signature = png
        withUnsafeBytes(of: cursor.hotSpot) { signature.append(contentsOf: $0) }
        guard signature != lastSignature else { return }
        lastSignature = signature
        let shape = Shape(pngBase64: png.base64EncodedString(), widthPoints: size.width, heightPoints: size.height,
                          hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y)
        current = shape
        onChange?(shape)
    }
}
