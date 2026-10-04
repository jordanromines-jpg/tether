// Renders the Mac UI (menu-bar panel, each Setup Assistant step) to PNGs in light and dark,
// with sample data, so it can be reviewed without running Tether or touching privacy prompts.
//   swift run --package-path agent Snapshots <output-folder>
import AppKit
import SwiftUI
import TetherCore
import TetherUI

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "snapshots")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
_ = NSApplication.shared

func render<V: View>(_ view: V, _ name: String) {
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .aqua ? .windowBackgroundColor : NSColor(white: 0.16, alpha: 1)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = out.appendingPathComponent("\(name)-\(suffix).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}

let sampleURL = "https://studio.tail1234.ts.net"

// Menu-bar panel: two devices connected, and the first-run case with a missing permission.
let panel = PanelModel()
panel.url = sampleURL
panel.sessions = [
    SessionRow(id: UUID(), device: "iPhone", login: "owner@example.com", since: Date().addingTimeInterval(-1800)),
    SessionRow(id: UUID(), device: "iPad", login: "owner@example.com", since: Date().addingTimeInterval(-300)),
]
panel.loginItemInstalled = true
panel.startAtLogin = true
render(StatusPanelView(model: panel).background(.background), "panel-connected")

let fresh = PanelModel()
fresh.url = sampleURL
fresh.inputAllowed = false
fresh.passkeyRequired = true
fresh.passkeyCount = 2
fresh.loginItemInstalled = true
render(StatusPanelView(model: fresh).background(.background), "panel-needs-permission")

let paused = PanelModel()
paused.paused = true
paused.url = sampleURL
render(StatusPanelView(model: paused).background(.background), "panel-paused")

// Setup Assistant, every step.
let setup = SetupModel()
setup.screenAllowed = true
setup.inputAllowed = false
setup.loginItemInstalled = true
setup.tailnet = TailnetStatus(running: true, needsLogin: false, dnsName: "studio.tail1234.ts.net", httpsEnabled: true)
for step in SetupStep.allCases {
    setup.step = step
    render(SetupAssistantView(model: setup), "setup-\(step.rawValue)-\(step)")
}
let noCerts = SetupModel()
noCerts.tailnet = TailnetStatus(running: true, needsLogin: false, dnsName: "studio.tail1234.ts.net", httpsEnabled: false)
noCerts.step = .network
render(SetupAssistantView(model: noCerts), "setup-2-network-https-off")
