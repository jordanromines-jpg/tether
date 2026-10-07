import Foundation

/// The parts of `tailscale status --json` the Setup Assistant needs.
public struct TailnetStatus: Equatable, Sendable {
    public var running: Bool          // BackendState == "Running" (installed, signed in, connected)
    public var needsLogin: Bool       // BackendState == "NeedsLogin"
    public var dnsName: String?       // this Mac's name on the tailnet, without the trailing dot
    public var httpsEnabled: Bool     // HTTPS certificates are on for the tailnet (CertDomains present)

    public init(running: Bool, needsLogin: Bool, dnsName: String?, httpsEnabled: Bool) {
        self.running = running
        self.needsLogin = needsLogin
        self.dnsName = dnsName
        self.httpsEnabled = httpsEnabled
    }

    public static let unavailable = TailnetStatus(running: false, needsLogin: false, dnsName: nil, httpsEnabled: false)

    public var url: String? { dnsName.map { "https://\($0)" } }

    public static func parse(_ data: Data) -> TailnetStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        let state = obj["BackendState"] as? String ?? ""
        let dns = ((obj["Self"] as? [String: Any])?["DNSName"] as? String)
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .flatMap { $0.isEmpty ? nil : $0 }
        let certs = (obj["CertDomains"] as? [Any]).map { !$0.isEmpty } ?? false
        return TailnetStatus(running: state == "Running", needsLogin: state == "NeedsLogin", dnsName: dns, httpsEnabled: certs)
    }
}

/// When the Setup Assistant opens by itself.
public enum SetupPolicy {
    /// Everything the Setup Assistant walks through is done: permissions, a working tailnet with HTTPS,
    /// and a device has connected. Then it can say "All set" and close itself.
    public static func isComplete(screenAllowed: Bool, inputAllowed: Bool, tailnet: TailnetStatus?, deviceConnected: Bool) -> Bool {
        guard let tailnet else { return false }
        return screenAllowed && inputAllowed && tailnet.running && !tailnet.needsLogin && tailnet.httpsEnabled && deviceConnected
    }

    /// On the first launch, when asked for (tether://setup), or whenever a permission Tether needs is missing.
    public static func shouldOpenAssistant(onboarded: Bool, requested: Bool, screenAllowed: Bool, inputAllowed: Bool) -> Bool {
        requested || !onboarded || !screenAllowed || !inputAllowed
    }
}

/// Shortcuts Tether created (Finder aliases and viewer apps), recorded in shortcuts.json so
/// uninstall.sh removes exactly those and nothing else. The file is a JSON array of paths.
public struct ShortcutRegistry: Equatable, Sendable {
    public private(set) var paths: [String]

    public init(paths: [String] = []) { self.paths = paths }

    public init(json: Data?) {
        let list = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? []
        self.paths = list.compactMap { $0 as? String }.filter { $0.hasPrefix("/") }
    }

    public mutating func add(_ path: String) {
        guard path.hasPrefix("/"), !paths.contains(path) else { return }
        paths.append(path)
    }

    public mutating func remove(_ path: String) { paths.removeAll { $0 == path } }

    public var json: Data { (try? JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted])) ?? Data("[]".utf8) }
}
