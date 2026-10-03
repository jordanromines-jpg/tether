import AppKit

/// Watches the Mac pasteboard and applies text sent from clients.
final class ClipboardSync {
    var onChange: ((String) -> Void)?
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
            onChange?(s)
        }
    }
}
