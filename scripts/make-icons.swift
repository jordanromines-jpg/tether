// Renders the app icons, the maskable icon and the iPhone/iPad launch screens:
//   swift scripts/make-icons.swift web/icons
// Prints the <link rel="apple-touch-startup-image"> tags for web/index.html.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "web/icons")

/// The icon: background gradient, then the display, stand and pointer, drawn in `r` (art at `art` of
/// its size: 1 for the normal icon, smaller for the maskable one, whose edges may be cut off).
func drawIcon(in r: NSRect, art: CGFloat = 1, background: Bool = true) {
    if background {
        NSGradient(starting: NSColor(red: 0.12, green: 0.13, blue: 0.17, alpha: 1),
                   ending: NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1))!.draw(in: r, angle: -90)
    }
    let s = r.width * art
    let o = NSPoint(x: r.minX + (r.width - s) / 2, y: r.minY + (r.height - s) / 2)
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: o.x + s * x, y: o.y + s * y, width: s * w, height: s * h) }
    let screenPath = NSBezierPath(roundedRect: R(0.17, 0.33, 0.66, 0.42), xRadius: s * 0.045, yRadius: s * 0.045)
    NSGradient(starting: NSColor(red: 0.36, green: 0.58, blue: 1, alpha: 1),
               ending: NSColor(red: 0.2, green: 0.36, blue: 0.95, alpha: 1))!.draw(in: screenPath, angle: -60)
    NSColor(white: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: R(0.44, 0.23, 0.12, 0.1), xRadius: s * 0.01, yRadius: s * 0.01).fill()
    NSBezierPath(roundedRect: R(0.34, 0.2, 0.32, 0.04), xRadius: s * 0.02, yRadius: s * 0.02).fill()
    let p = NSBezierPath()
    let ox = o.x + s * 0.47, oy = o.y + s * 0.66, k = s * 0.0042
    for (i, pt) in [(0.0, 0.0), (0.0, -40.0), (10.0, -30.0), (17.0, -45.0), (24.0, -42.0), (17.0, -27.0), (30.0, -27.0)].enumerated() {
        let q = NSPoint(x: ox + pt.0 * k, y: oy + pt.1 * k)
        if i == 0 { p.move(to: q) } else { p.line(to: q) }
    }
    p.close()
    NSColor.white.setFill(); p.fill()
    NSColor(white: 0, alpha: 0.35).setStroke(); p.lineWidth = s * 0.006; p.stroke()
}

func render(_ w: Int, _ h: Int, to name: String, opaque: Bool = false, _ draw: (NSRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: opaque ? 3 : 4, hasAlpha: !opaque, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: opaque ? 32 : 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for size in [180, 192, 512, 1024] {
    render(size, size, to: "icon-\(size).png") { drawIcon(in: $0) }
}
// Maskable (Android and others crop it to a circle or squircle): the art inside the 80% safe zone.
render(512, 512, to: "icon-maskable-512.png") { drawIcon(in: $0, art: 0.72) }

// Launch screens: the page's dark background (--bg, #0c0d10) with the icon in the middle.
// Current iPhones and iPads, portrait and landscape: (CSS width, height, pixel ratio).
let devices: [(Int, Int, Int)] = [
    (440, 956, 3), (402, 874, 3), (430, 932, 3), (393, 852, 3), (390, 844, 3), (428, 926, 3), (375, 812, 3), (375, 667, 2),
    (1032, 1376, 2), (1024, 1366, 2), (834, 1210, 2), (834, 1194, 2), (820, 1180, 2), (810, 1080, 2), (744, 1133, 2),
]
var tags: [String] = []
for (w, h, dpr) in devices {
    for portrait in [true, false] {
        let pw = (portrait ? w : h) * dpr, ph = (portrait ? h : w) * dpr
        let name = "launch/launch-\(pw)x\(ph).png"
        render(pw, ph, to: name, opaque: true) { r in
            NSColor(red: 0x0c / 255, green: 0x0d / 255, blue: 0x10 / 255, alpha: 1).setFill()
            r.fill()
            let side = CGFloat(96 * dpr), icon = NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: icon, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
            drawIcon(in: icon)
            NSGraphicsContext.restoreGraphicsState()
        }
        tags.append(#"<link rel="apple-touch-startup-image" href="icons/\#(name)" media="(device-width: \#(w)px) and (device-height: \#(h)px) and (-webkit-device-pixel-ratio: \#(dpr)) and (orientation: \#(portrait ? "portrait" : "landscape"))">"#)
        // iPads in landscape may report the screen rotated too; match that form as well.
        if !portrait && w > 700 {
            tags.append(#"<link rel="apple-touch-startup-image" href="icons/\#(name)" media="(device-width: \#(h)px) and (device-height: \#(w)px) and (-webkit-device-pixel-ratio: \#(dpr)) and (orientation: landscape)">"#)
        }
    }
}
print("wrote icons, maskable icon and \(tags.count) launch screens to \(outDir.path)")
print(tags.joined(separator: "\n"))
