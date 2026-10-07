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

// v4: curtain on, a view-only session that's been idle, help links in the footer.
let curtained = PanelModel()
curtained.url = sampleURL
curtained.curtainOn = true
curtained.sessions = [
    SessionRow(id: UUID(), device: "Jordan's iPhone", login: "owner@example.com", since: Date().addingTimeInterval(-3600),
               viewOnly: true, lastInput: Date().addingTimeInterval(-14 * 60)),
]
render(StatusPanelView(model: curtained).background(.background), "panel-curtain-viewing")
render(CurtainView().frame(width: 960, height: 600), "curtain")

// v4 batch 2: update banner, recent activity, each device's passkey.
let busy = PanelModel()
busy.url = sampleURL
busy.update = .availableManual
busy.passkeyRequired = true
busy.passkeys = [PasskeyRow(id: "a", device: "Jordan's iPhone", created: Date().addingTimeInterval(-86400 * 12)),
                 PasskeyRow(id: "b", device: "iPad", created: Date().addingTimeInterval(-86400 * 3))]
busy.activity = [
    ActivityEntry(id: UUID(), login: "owner@example.com", device: "Jordan's iPhone", start: Date().addingTimeInterval(-600)),
    ActivityEntry(id: UUID(), login: "owner@example.com", device: "iPad", start: Date().addingTimeInterval(-7200),
                  end: Date().addingTimeInterval(-7200 + 47 * 60), viewOnly: true),
    ActivityEntry(id: UUID(), login: "owner@example.com", device: "Mac", start: Date().addingTimeInterval(-86400),
                  end: Date().addingTimeInterval(-86400 + 20)),
]
render(StatusPanelView(model: busy).background(.background), "panel-activity-passkeys-update")

// Live update check: SNAPSHOT_UPDATE_PLIST=<built Tether.app/Contents/Info.plist> asks GitHub for the
// newest commit, exactly as the app does, and renders the panel with the real answer.
if let plist = ProcessInfo.processInfo.environment["SNAPSHOT_UPDATE_PLIST"],
   let info = NSDictionary(contentsOfFile: plist) {
    let repo = info["TetherRepo"] as? String ?? Links.defaultRepo
    let built = (info["TetherBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/commits/main")!, timeoutInterval: 8)
    request.setValue("Tether", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    var remote: Date?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in remote = data.flatMap(UpdateCheck.latestCommitDate); done.signal() }.resume()
    done.wait()
    let live = PanelModel()
    live.url = sampleURL
    let newer = UpdateCheck.isNewer(remote: remote, build: built)
    live.update = newer ? .availableManual : nil
    print("update check: repo \(repo), built \(built.map { "\($0)" } ?? "unknown"), latest \(remote.map { "\($0)" } ?? "unknown"), available \(newer)")
    render(StatusPanelView(model: live).background(.background), "panel-update-live")
}

// v5: every state of the update banner.
let banners: [(String, UpdateBanner)] = [
    ("here", .availableHere(count: 3, whatsNew: ["Toolbar labels and a key row above the keyboard",
                                                  "One-click updates from the menu bar",
                                                  "Fix the connection row in More"])),
    ("elsewhere", .availableElsewhere(from: "Jordan's MacBook Pro")),
    ("updating", .updating(message: "Building (usually a few minutes)")),
    ("updated", .updated(version: "4f2c9e1")),
    ("failed", .failed(message: "This copy has changes of its own that aren't committed. Update it in Terminal.")),
]
for (name, banner) in banners {
    let m = PanelModel()
    m.url = sampleURL
    m.update = banner
    render(StatusPanelView(model: m).background(.background), "panel-update-\(name)")
}

// v6: the Update window, the crash note, Setup's "All set" countdown.
for (name, banner) in [("available", UpdateBanner.availableHere(count: 3, whatsNew: [])), ("updating", .updating(message: "Building (usually a few minutes)")),
                       ("updated", .updated(version: "4f2c9e1")), ("failed", .failed(message: "Couldn't reach GitHub. Check the internet connection and try again."))] {
    let m = PanelModel()
    m.update = banner
    m.whatsNew = name == "updating" ? [] : ["Explain why a Mac can't be reached", "Diagnose button on the connection card", "Update in its own window"]
    render(UpdateView(model: m).background(.background), "update-window-\(name)")
}
let crashed = PanelModel()
crashed.url = sampleURL
crashed.crashedAt = Date().addingTimeInterval(-3600)
render(StatusPanelView(model: crashed).background(.background), "panel-crash")
let allSet = SetupModel()
allSet.screenAllowed = true
allSet.inputAllowed = true
allSet.loginItemInstalled = true
allSet.tailnet = TailnetStatus(running: true, needsLogin: false, dnsName: "studio.tail1234.ts.net", httpsEnabled: true)
allSet.step = .done
allSet.closingIn = 4
render(SetupAssistantView(model: allSet), "setup-all-set")

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
