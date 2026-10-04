import AppKit
import TetherUI

/// A small window showing the Tether link as a QR code, for scanning with a phone.
final class QRWindowController: NSWindowController {
    convenience init(url: String) {
        let size: CGFloat = 280
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size + 40, height: size + 110),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Open Tether on your phone"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let imageView = NSImageView(image: QRCode.image(for: url, size: size) ?? NSImage())
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: size).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: size).isActive = true

        let hint = NSTextField(wrappingLabelWithString: "Scan with your iPhone or iPad camera. The device needs Tailscale, signed in to the same account.")
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = size

        let link = NSTextField(labelWithString: url)
        link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        link.isSelectable = true
        link.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(link)
        stack.addArrangedSubview(hint)
        window.contentView = stack
        window.center()
        self.init(window: window)
    }
}
