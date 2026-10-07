import SwiftUI
import TetherCore

/// One connected viewer, as shown in the panel.
/// One enrolled passkey, as listed in the panel.
public struct PasskeyRow: Identifiable, Equatable {
    public let id: String
    public let device: String
    public let created: Date
    public init(id: String, device: String, created: Date) { self.id = id; self.device = device; self.created = created }
}

public struct SessionRow: Identifiable, Equatable {
    public let id: UUID
    public let device: String
    public let login: String
    public let since: Date
    public let viewOnly: Bool
    public let lastInput: Date
    public init(id: UUID, device: String, login: String, since: Date, viewOnly: Bool = false, lastInput: Date = Date()) {
        self.id = id; self.device = device; self.login = login; self.since = since
        self.viewOnly = viewOnly; self.lastInput = lastInput
    }

    public var detail: String { "\(login), since \(since.formatted(date: .omitted, time: .shortened))" }

    /// "Viewing only, idle 14 min" (idle shows after 2 minutes without input), or nil.
    public func activity(now: Date = Date()) -> String? {
        var parts: [String] = []
        if viewOnly { parts.append("Viewing only") }
        let idle = Int(now.timeIntervalSince(lastInput) / 60)
        if idle >= 2 { parts.append(parts.isEmpty ? "Idle \(idle) min" : "idle \(idle) min") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The update banner at the top of the panel.
public enum UpdateBanner: Equatable {
    /// "Update now" rebuilds on this Mac; `whatsNew` are the newest commit subjects.
    case availableHere(count: Int, whatsNew: [String])
    /// Another Mac builds and installs Tether here.
    case availableElsewhere(from: String)
    /// No record of where updates come from (an older install).
    case availableManual
    case updating(message: String)
    case updated(version: String)
    case failed(message: String)

    var title: String {
        switch self {
        case .availableHere, .availableElsewhere, .availableManual: return "Update available"
        case .updating: return "Updating Tether"
        case .updated: return "Tether is up to date"
        case .failed: return "The update didn't finish"
        }
    }

    var detail: String {
        switch self {
        case .availableHere(let count, _):
            let changes = count == 1 ? "1 change" : "\(count) changes"
            return count > 0 ? "\(changes) since this copy. It takes a few minutes, and connected devices reconnect by themselves."
                             : "A newer Tether is on GitHub. It takes a few minutes, and connected devices reconnect by themselves."
        case .availableElsewhere(let from):
            return "Update it from \(from): open Tether Updater there, or copy the command and run it in its Tether folder."
        case .availableManual: return "A newer Tether is on GitHub."
        case .updating(let message): return message
        case .updated(let version): return "Updated to \(version)."
        case .failed(let message): return message
        }
    }

    var symbol: String {
        switch self {
        case .updated: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .updated: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }
}

/// What the menu-bar panel can do. The app fills these in; Snapshots leaves them empty.
public struct PanelActions {
    public var setPaused: (Bool) -> Void = { _ in }
    public var copyLink: () -> Void = {}
    public var showQR: () -> Void = {}
    public var disconnect: (UUID) -> Void = { _ in }
    public var disconnectAll: () -> Void = {}
    public var setPasskeyRequired: (Bool) -> Void = { _ in }
    public var openEnrollment: () -> Void = {}
    public var removePasskeys: () -> Void = {}
    public var openScreenRecording: () -> Void = {}
    public var openAccessibility: () -> Void = {}
    public var setStartAtLogin: (Bool) -> Void = { _ in }
    public var openSetup: () -> Void = {}
    public var addShortcut: () -> Void = {}
    public var quit: () -> Void = {}
    public var setCurtain: (Bool) -> Void = { _ in }
    public var openHelp: () -> Void = {}
    public var reportProblem: () -> Void = {}
    public var removePasskey: (String) -> Void = { _ in }
    public var showAllActivity: () -> Void = {}
    public var setCheckUpdates: (Bool) -> Void = { _ in }
    public var openUpdateHelp: () -> Void = {}
    public var updateNow: () -> Void = {}
    public var copyUpdateCommand: () -> Void = {}
    public var showUpdateLog: () -> Void = {}
    public var dismissUpdate: () -> Void = {}
    public var reportCrash: () -> Void = {}
    public var dismissCrash: () -> Void = {}
    public init() {}
}

public final class PanelModel: ObservableObject {
    @Published public var paused = false
    @Published public var sessions: [SessionRow] = []
    @Published public var url: String?
    @Published public var screenAllowed = true
    @Published public var inputAllowed = true
    @Published public var passkeyRequired = false
    @Published public var passkeyCount = 0
    @Published public var enrolling = false
    @Published public var loginItemInstalled = false
    @Published public var startAtLogin = false
    @Published public var linkCopied = false
    @Published public var curtainOn = false
    @Published public var activity: [ActivityEntry] = []
    @Published public var passkeys: [PasskeyRow] = []
    @Published public var update: UpdateBanner?
    /// Commit subjects for the Update window (what's coming, or what just arrived).
    @Published public var whatsNew: [String] = []
    /// When Tether last quit unexpectedly (shown once, until dismissed).
    @Published public var crashedAt: Date?
    @Published public var checkUpdates = true
    public var actions = PanelActions()
    public init() {}

    var statusLine: String {
        if paused { return "Paused. Nobody can connect." }
        switch sessions.count {
        case 0: return "Ready. Nobody is connected."
        case 1: return "1 device connected"
        default: return "\(sessions.count) devices connected"
        }
    }
}

/// The panel that opens from the menu-bar icon.
public struct StatusPanelView: View {
    @ObservedObject var model: PanelModel
    public init(model: PanelModel) { self.model = model }

    private var accessOn: Binding<Bool> {
        Binding(get: { !model.paused }, set: { on in model.paused = !on; model.actions.setPaused(!on) })
    }
    private var passkey: Binding<Bool> {
        Binding(get: { model.passkeyRequired }, set: { model.passkeyRequired = $0; model.actions.setPasskeyRequired($0) })
    }
    private var login: Binding<Bool> {
        Binding(get: { model.startAtLogin }, set: { model.startAtLogin = $0; model.actions.setStartAtLogin($0) })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let banner = model.update { update(banner) }
                if let crashedAt = model.crashedAt { crash(crashedAt) }
                if model.curtainOn { curtain }
                if !model.screenAllowed || !model.inputAllowed { permissions }
                if let url = model.url, !model.paused { link(url) }
                devices
                if !model.activity.isEmpty { activity }
                passkeys
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: MenuBarIcon.image(model.paused ? .paused : model.sessions.isEmpty ? .idle : .connected))
                .renderingMode(.template)
                .foregroundStyle(model.paused ? Color.secondary : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote access").font(.headline)
                Text(model.statusLine).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("Remote access", isOn: accessOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.paused ? "Turn remote access back on" : "Pause remote access and disconnect everyone")
        }
        .padding(14)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tether needs permission to work", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            if !model.screenAllowed {
                permissionRow("Screen Recording", "So your devices can see the screen.", model.actions.openScreenRecording)
            }
            if !model.inputAllowed {
                permissionRow("Accessibility", "So your devices can click and type.", model.actions.openAccessibility)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }

    private func permissionRow(_ title: String, _ detail: String, _ open: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings", action: open).controlSize(.small)
        }
    }

    private func link(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your link").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(url.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    model.actions.copyLink()
                    model.linkCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.linkCopied = false }
                } label: { Image(systemName: model.linkCopied ? "checkmark" : "doc.on.doc") }
                .help("Copy link")
                .accessibilityLabel("Copy link")
                Button { model.actions.showQR() } label: { Image(systemName: "qrcode") }
                    .help("Show a QR code to open Tether on your phone")
                    .accessibilityLabel("Show QR code")
            }
            .buttonStyle(.borderless)
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.sessions.count > 1 {
                    Button("Disconnect all", action: model.actions.disconnectAll).buttonStyle(.borderless).font(.caption)
                }
            }
            if model.sessions.isEmpty {
                Text(model.paused ? "No one can connect while paused." : "No one is connected right now.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions) { s in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: s.device)).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.device).font(.callout.weight(.medium))
                            Text(s.detail)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let a = s.activity() {
                                Text(a).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                            }
                        }
                        Spacer()
                        Button("Disconnect") { model.actions.disconnect(s.id) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private func icon(for device: String) -> String {
        // Devices can be renamed ("Jordan's iPhone"), so match by what the name contains.
        let d = device.lowercased()
        if d.contains("iphone") { return "iphone" }
        if d.contains("ipad") { return "ipad" }
        if d.contains("mac") { return "laptopcomputer" }
        if d.contains("android") { return "candybarphone" }
        return "display"
    }

    private var passkeys: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Require Face ID or Touch ID").font(.callout)
                    Text("Each device unlocks with a passkey before it can connect.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Require Face ID or Touch ID", isOn: passkey).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            if model.passkeyRequired && !model.passkeys.isEmpty {
                ForEach(model.passkeys) { k in
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(k.device).font(.callout)
                            Text("Added \(k.created.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.actions.removePasskey(k.id) }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Removes this passkey and signs every device out; the others unlock again with Face ID")
                    }
                }
            }
            if model.passkeyRequired {
                HStack {
                    Button(model.enrolling ? "Waiting for a device…" : "Add a passkey", action: model.actions.openEnrollment)
                        .disabled(model.enrolling)
                        .help("Lets a device create a passkey during the next 10 minutes")
                    if model.passkeyCount > 0 {
                        Button("Remove all (\(model.passkeyCount))", role: .destructive, action: model.actions.removePasskeys)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func update(_ banner: UpdateBanner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.symbol).foregroundStyle(banner.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.subheadline.weight(.semibold))
                    Text(banner.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if case .updating = banner { ProgressView().controlSize(.small) }
            }
            if case .updated = banner, !model.whatsNew.isEmpty { whatsNewList(model.whatsNew) }
            if case .availableHere(_, let whatsNew) = banner, !whatsNew.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What's new").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(whatsNew.enumerated()), id: \.offset) { _, line in
                        Text("· \(line)").font(.caption).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            updateButtons(banner)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(banner.tint.opacity(0.1)))
    }

    private func whatsNewList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("What's new").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("· \(line)").font(.caption).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func crash(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tether quit unexpectedly (\(Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)))").font(.subheadline.weight(.semibold))
                    Text("It started again by itself. A report helps fix it, and you'll see it before anything is sent.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Report a problem", action: model.actions.reportCrash).controlSize(.small)
                Button("Dismiss", action: model.actions.dismissCrash).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }

    @ViewBuilder
    private func updateButtons(_ banner: UpdateBanner) -> some View {
        switch banner {
        case .availableHere:
            HStack { Spacer(); Button("Update now", action: model.actions.updateNow).buttonStyle(.borderedProminent).controlSize(.small) }
        case .availableElsewhere:
            HStack { Spacer(); Button("Copy command", action: model.actions.copyUpdateCommand).controlSize(.small) }
        case .availableManual:
            HStack { Spacer(); Button("How to update", action: model.actions.openUpdateHelp).controlSize(.small) }
        case .updating:
            EmptyView()
        case .updated:
            HStack { Spacer(); Button("OK", action: model.actions.dismissUpdate).controlSize(.small) }
        case .failed:
            HStack {
                Spacer()
                Button("Show log", action: model.actions.showUpdateLog).controlSize(.small)
                Button("Dismiss", action: model.actions.dismissUpdate).controlSize(.small)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Show all", action: model.actions.showAllActivity).buttonStyle(.borderless).font(.caption)
            }
            ForEach(model.activity.prefix(3), id: \.id) { e in
                ActivityRowView(entry: e)
            }
        }
    }

    private var curtain: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Curtain is on").font(.subheadline.weight(.semibold))
                Text("This Mac's screen is black for anyone in the room.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn off") { model.curtainOn = false; model.actions.setCurtain(false) }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.loginItemInstalled {
                Toggle("Start Tether at login", isOn: login).toggleStyle(.checkbox).padding(.horizontal, 14).padding(.vertical, 6)
            }
            Toggle("Check for updates", isOn: Binding(get: { model.checkUpdates },
                                                       set: { model.checkUpdates = $0; model.actions.setCheckUpdates($0) }))
                .toggleStyle(.checkbox).padding(.horizontal, 14).padding(.bottom, 4)
                .help("Once a day, asks GitHub whether a newer Tether exists")
            FooterButton(title: "Setup Assistant…", symbol: "wand.and.stars", action: model.actions.openSetup)
            FooterButton(title: "Add a shortcut…", symbol: "plus.app", action: model.actions.addShortcut)
            FooterButton(title: "Help and docs", symbol: "questionmark.circle", action: model.actions.openHelp)
            FooterButton(title: "Report a problem", symbol: "exclamationmark.bubble", action: model.actions.reportProblem)
            FooterButton(title: "Quit Tether", symbol: "power", action: model.actions.quit)
                .help("Tether stays off until you open it again from Applications")
        }
        .padding(.vertical, 6)
    }
}

/// A full-width menu-style row button for the panel footer.
struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    // A tiny ObservableObject instead of @State: on recent SDKs @State is a macro, and the
    // Command Line Tools ship without macro plugins.
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover.on ? Color.primary.opacity(0.08) : .clear).padding(.horizontal, 6))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

final class Hover: ObservableObject { @Published var on = false }

/// One line of the activity list: device, when, how long.
public struct ActivityRowView: View {
    let entry: ActivityEntry
    public init(entry: ActivityEntry) { self.entry = entry }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.device + (entry.viewOnly ? " (viewing)" : "")).font(.callout)
                Text(entry.login).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(entry.start.formatted(.relative(presentation: .named))).font(.caption)
                Text(entry.durationText()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Show all" activity window.
public struct ActivityListView: View {
    let entries: [ActivityEntry]
    public init(entries: [ActivityEntry]) { self.entries = entries }
    public var body: some View {
        Group {
            if entries.isEmpty {
                Text("No one has connected yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries, id: \.id) { ActivityRowView(entry: $0).padding(.vertical, 2) }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}


/// The Update Tether window: the same update as the panel's banner, in a window that stays open
/// while you use the Mac (a popover closes as soon as you click anything else).
public struct UpdateView: View {
    @ObservedObject var model: PanelModel
    public init(model: PanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = model.update {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: banner.symbol).font(.system(size: 28)).foregroundStyle(banner.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(banner.title).font(.title3.weight(.semibold))
                        Text(banner.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if case .updating = banner { ProgressView().controlSize(.small) }
                }
                if !model.whatsNew.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What's new").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(model.whatsNew.enumerated()), id: \.offset) { _, line in
                            Text("· \(line)").font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Spacer()
                    switch banner {
                    case .availableHere:
                        Button("Update now", action: model.actions.updateNow).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    case .updating:
                        Text("You can keep using the Mac. Tether restarts at the end.").font(.caption).foregroundStyle(.secondary)
                    case .failed:
                        Button("Show log", action: model.actions.showUpdateLog)
                        Button("Close", action: model.actions.dismissUpdate).keyboardShortcut(.defaultAction)
                    default:
                        Button("Close", action: model.actions.dismissUpdate).keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Text("Tether is up to date.").font(.title3.weight(.semibold))
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
