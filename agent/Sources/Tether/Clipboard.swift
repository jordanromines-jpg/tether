import AppKit

/// Watches the Mac pasteboard and applies what clients send: plain and rich text, and images.
final class ClipboardSync {
    var onChange: ((String, String?) -> Void)?           // text, and its HTML when there is some
    var onImage: ((Int, Int, Int) -> Void)?              // id, width, height (fetch it from /clipboard/image)
    private let imageLock = NSLock()
    private var image: (id: Int, png: Data)?
    private var nextImageID = 1
    static let maxImageBytes = 8 << 20
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        DispatchQueue.main.async {
            guard self.timer == nil else { return }
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    func set(_ text: String) {
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastChangeCount = pb.changeCount  // don't echo it back
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if let s = pb.string(forType: .string), !s.isEmpty, s.utf8.count <= 1_000_000 {
            let html = pb.string(forType: .html).flatMap { $0.utf8.count <= 1_000_000 ? $0 : nil }
            onChange?(s, html)
        } else if let png = Self.pngFromPasteboard(pb), png.count <= Self.maxImageBytes,
                  let rep = NSBitmapImageRep(data: png) {
            let id = imageLock.withLock { () -> Int in
                defer { nextImageID += 1 }
                image = (nextImageID, png)
                return nextImageID
            }
            onImage?(id, rep.pixelsWide, rep.pixelsHigh)
        }
    }

    private static func pngFromPasteboard(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The latest copied image, if `id` still matches it.
    func image(id: Int) -> Data? { imageLock.withLock { image?.id == id ? image?.png : nil } }

    /// Puts an image from a device on the Mac's clipboard (as PNG and TIFF, so every app can paste it).
    func set(image png: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: png) else { return false }
        let tiff = rep.tiffRepresentation
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            if let tiff { pb.setData(tiff, forType: .tiff) }
            self.lastChangeCount = pb.changeCount
        }
        return true
    }
}
