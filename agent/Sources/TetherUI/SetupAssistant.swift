import SwiftUI
import TetherCore

public enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, network, phone, done
    public var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .network: "Network"
        case .phone: "Your phone"
        case .done: "Finish"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .permissions: "lock.shield"
        case .network: "network"
        case .phone: "iphone"
        case .done: "flag.checkered"
        }
    }
}

public struct SetupActions {
    public var openScreenRecording: () -> Void = {}
    public var openAccessibility: () -> Void = {}
    public var revealApp: () -> Void = {}
    public var openTailscale: () -> Void = {}
    public var openTailscaleDownload: () -> Void = {}
    public var openAdminDNS: () -> Void = {}
    public var copy: (String) -> Void = { _ in }
    public var chooseFolder: () -> URL? = { nil }
    public var finish: () -> Void = {}
    public var openHelp: () -> Void = {}
    public init() {}
}

public final class SetupModel: ObservableObject {
    @Published public var step: SetupStep = .welcome { didSet { visited.insert(step) } }
    @Published public var visited: Set<SetupStep> = [.welcome]
    @Published public var screenAllowed = false
    @Published public var inputAllowed = false
    @Published public var tailscaleInstalled = true
    @Published public var tailnet: TailnetStatus = .unavailable
    @Published public var loginItemInstalled = false
    @Published public var startAtLogin = true
    @Published public var addShortcut = true
    @Published public var shortcutFolder = URL(fileURLWithPath: "/Applications")
    @Published public var copied: String?
    public var actions = SetupActions()
    public init() {}

    public var permissionsDone: Bool { screenAllowed && inputAllowed }
    public var networkDone: Bool { tailnet.running && tailnet.httpsEnabled }
    public var url: String? { tailnet.url }
    public var viewerCommand: String { "scripts/shortcut.sh viewer \(url ?? "https://your-mac.your-tailnet.ts.net")" }

    func isComplete(_ s: SetupStep) -> Bool {
        switch s {
        case .welcome, .phone: visited.contains(s) && s != step
        case .permissions: permissionsDone
        case .network: networkDone
        case .done: false
        }
    }

    func copy(_ text: String) {
        actions.copy(text)
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in if self?.copied == text { self?.copied = nil } }
    }
}

public struct SetupAssistantView: View {
    @ObservedObject var model: SetupModel
    public init(model: SetupModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 16)
                }
                Divider()
                navigation
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 760, height: 540)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarIcon.image(.idle)).renderingMode(.template).foregroundStyle(Color.accentColor)
                Text("Set up Tether").font(.headline)
            }
            .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 14)
            ForEach(SetupStep.allCases) { s in
                Button { model.step = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.isComplete(s) ? "checkmark.circle.fill" : s.symbol)
                            .foregroundStyle(model.isComplete(s) ? Color.green : (s == model.step ? Color.accentColor : Color.secondary))
                            .frame(width: 20)
                        Text(s.title).foregroundStyle(s == model.step ? Color.primary : Color.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(s == model.step ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityLabel("\(s.title)\(model.isComplete(s) ? ", done" : "")")
            }
            Spacer()
        }
        .frame(width: 200)
        .background(.regularMaterial)
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .permissions: permissions
        case .network: network
        case .phone: phone
        case .done: done
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Welcome to Tether", "See and control this Mac from your iPhone, iPad or another computer. This takes about two minutes.")
            Fact(symbol: "lock", title: "Private by design",
                 text: "Only devices signed in to your own Tailscale account can reach this Mac. Nothing is open to the internet.")
            Fact(symbol: "menubar.rectangle", title: "Lives in your menu bar",
                 text: "Tether runs quietly in the menu bar. Click its icon to pause it, see who's connected, or come back here.")
            Fact(symbol: "checklist", title: "What's next",
                 text: "Allow two permissions, check your network, then open Tether on your phone.")
            Button("Learn more about Tether", action: model.actions.openHelp).buttonStyle(.link).padding(.leading, 42)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Allow two permissions", "macOS asks you to turn these on yourself. Tether can't do it for you, and that's on purpose.")
            PermissionCard(allowed: model.screenAllowed, title: "Screen Recording",
                           text: "Lets your devices see this Mac's screen.", open: model.actions.openScreenRecording)
            PermissionCard(allowed: model.inputAllowed, title: "Accessibility",
                           text: "Lets your devices click and type on this Mac.", open: model.actions.openAccessibility)
            VStack(alignment: .leading, spacing: 6) {
                Text("In each list, turn on **Tether**. If it isn't listed, click **+** and pick it, or drag it in from Finder.")
                Text("After an update, if Tether shows as on but this page still says it's needed, remove it with **−** and add it again.")
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Show Tether in Finder", action: model.actions.revealApp)
            Text("These checkmarks update by themselves.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Check your network", "Tether uses Tailscale to connect your devices privately, from anywhere.")
            StatusRow(ok: model.tailnet.running, title: tailscaleTitle, text: tailscaleText) {
                if !model.tailscaleInstalled {
                    Button("Get Tailscale", action: model.actions.openTailscaleDownload)
                } else if !model.tailnet.running {
                    Button("Open Tailscale", action: model.actions.openTailscale)
                }
            }
            StatusRow(ok: model.tailnet.httpsEnabled, title: model.tailnet.httpsEnabled ? "Secure link is on" : "Turn on secure links",
                      text: model.tailnet.httpsEnabled
                        ? "Your devices open Tether over HTTPS."
                        : "On Tailscale's DNS page, click Enable HTTPS. This adds your machine names (like my-mac.tailXXXX.ts.net) to a public certificate log. The names become visible, but nobody outside your tailnet can reach them.") {
                if model.tailnet.running && !model.tailnet.httpsEnabled {
                    Button("Open Tailscale DNS settings", action: model.actions.openAdminDNS)
                }
            }
            if let url = model.url, model.networkDone {
                CopyField(text: url, copied: model.copied == url) { model.copy(url) }
            }
        }
    }

    private var tailscaleTitle: String {
        if !model.tailscaleInstalled { return "Install Tailscale" }
        if model.tailnet.needsLogin { return "Sign in to Tailscale" }
        return model.tailnet.running ? "Tailscale is connected" : "Tailscale isn't connected"
    }
    private var tailscaleText: String {
        if !model.tailscaleInstalled { return "It's free. Install it, open it, and sign in." }
        if model.tailnet.needsLogin { return "Open Tailscale from the menu bar and sign in." }
        if model.tailnet.running { return "This Mac is \(model.tailnet.dnsName ?? "on your tailnet")." }
        return "Open Tailscale and make sure it's switched on."
    }

    private var phone: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Open Tether on your phone", "Do this once on each iPhone, iPad or computer you want to use.")
            HStack(alignment: .top, spacing: 24) {
                Group {
                    if let url = model.url, let qr = QRCode.image(for: url, size: 168) {
                        Image(nsImage: qr).interpolation(.none)
                            .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                            .accessibilityLabel("QR code for \(url)")
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                            .overlay(Text("The QR code appears when the network step is done.").font(.caption)
                                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding())
                    }
                }
                .frame(width: 188, height: 188)
                VStack(alignment: .leading, spacing: 12) {
                    NumberedStep(n: 1, text: "Install **Tailscale** on the phone and sign in with the same account as this Mac.")
                    NumberedStep(n: 2, text: "Point the camera at the code and open the link.")
                    NumberedStep(n: 3, text: "On iPhone or iPad, tap **Share**, then **Add to Home Screen**, so Tether opens like an app.")
                }
            }
            if let url = model.url { CopyField(text: url, copied: model.copied == url) { model.copy(url) } }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("You're all set", "A few last choices. You can change them later from the Tether menu.")
            if model.loginItemInstalled {
                Toggle(isOn: $model.startAtLogin) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start Tether when this Mac starts")
                        Text("Recommended, so you can always reach it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $model.addShortcut) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add a Tether shortcut to \(model.shortcutFolder.lastPathComponent)")
                        Text("Open it to start Tether again after you quit it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Choose folder…") { if let f = model.actions.chooseFolder() { model.shortcutFolder = f; model.addShortcut = true } }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Using another Mac to control this one?").font(.callout.weight(.medium))
                Text("Run this in the Tether folder on that Mac to get a Tether app that opens this screen in its own window.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                CopyField(text: model.viewerCommand, copied: model.copied == model.viewerCommand) { model.copy(model.viewerCommand) }
            }
            Label("Tether is in your menu bar. Click its icon any time.", systemImage: "menubar.arrow.up.rectangle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Navigation

    private var navigation: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.step = SetupStep(rawValue: model.step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            if model.step == .done {
                Button("Finish", action: model.actions.finish).keyboardShortcut(.defaultAction)
            } else {
                let next = { model.step = SetupStep(rawValue: model.step.rawValue + 1) ?? .done }
                let incomplete = (model.step == .permissions && !model.permissionsDone) || (model.step == .network && !model.networkDone)
                if incomplete { Button("Skip for now", action: next) }
                Button(model.step == .welcome ? "Get started" : "Continue", action: next)
                    .keyboardShortcut(.defaultAction)
                    .disabled(incomplete)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: Pieces

struct Fact: View {
    let symbol: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PermissionCard: View {
    let allowed: Bool, title: String, text: String, open: () -> Void
    var body: some View {
        StatusRow(ok: allowed, title: title, text: allowed ? "Allowed." : text) {
            if !allowed { Button("Open Settings", action: open) }
        }
    }
}

struct StatusRow<Trailing: View>: View {
    let ok: Bool, title: String, text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2).foregroundStyle(ok ? Color.green : Color.orange).frame(width: 28)
                .accessibilityLabel(ok ? "Done" : "Needed")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                trailing.padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct NumberedStep: View {
    let n: Int, text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CopyField: View {
    let text: String, copied: Bool, copy: () -> Void
    var body: some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(copied ? "Copied" : "Copy", action: copy).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
