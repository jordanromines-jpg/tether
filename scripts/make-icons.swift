// Renders the app icons: `swift scripts/make-icons.swift web/icons`
import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? "web/icons"
for size in [180, 192, 512, 1024] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Background gradient
    NSGradient(starting: NSColor(red: 0.12, green: 0.13, blue: 0.17, alpha: 1),
               ending: NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)
    // Display
    let screen = NSRect(x: s * 0.17, y: s * 0.33, width: s * 0.66, height: s * 0.42)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.045, yRadius: s * 0.045)
    NSGradient(starting: NSColor(red: 0.36, green: 0.58, blue: 1, alpha: 1),
               ending: NSColor(red: 0.2, green: 0.36, blue: 0.95, alpha: 1))!.draw(in: screenPath, angle: -60)
    // Stand
    NSColor(white: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.44, y: s * 0.23, width: s * 0.12, height: s * 0.1), xRadius: s * 0.01, yRadius: s * 0.01).fill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.34, y: s * 0.2, width: s * 0.32, height: s * 0.04), xRadius: s * 0.02, yRadius: s * 0.02).fill()
    // Pointer arrow
    let p = NSBezierPath()
    let ox = s * 0.47, oy = s * 0.66, k = s * 0.0042
    for (i, pt) in [(0.0, 0.0), (0.0, -40.0), (10.0, -30.0), (17.0, -45.0), (24.0, -42.0), (17.0, -27.0), (30.0, -27.0)].enumerated() {
        let q = NSPoint(x: ox + pt.0 * k, y: oy + pt.1 * k)
        if i == 0 { p.move(to: q) } else { p.line(to: q) }
    }
    p.close()
    NSColor.white.setFill(); p.fill()
    NSColor(white: 0, alpha: 0.35).setStroke(); p.lineWidth = s * 0.006; p.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon-\(size).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}
