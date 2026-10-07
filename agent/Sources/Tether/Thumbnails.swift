import AppKit
import ScreenCaptureKit

/// Small JPEG snapshots of a display, for the "Your Macs" picker and the displays overview.
/// Tether's own windows (the curtain) are left out, like in the stream.
enum Thumbnails {
    static func capture(display id: CGDirectDisplayID?, width: Int) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == (id ?? CGMainDisplayID()) }) ?? content.displays.first
        else { return nil }
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = max(1, Int(Double(width) * Double(display.height) / Double(max(display.width, 1))))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.65])
    }
}
