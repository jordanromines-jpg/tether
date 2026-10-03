import Foundation

/// Decides whether an incoming request may use the agent.
///
/// The agent binds to 127.0.0.1 only and is published to the tailnet via
/// `tailscale serve`, which stamps every proxied request with the caller's
/// verified `Tailscale-User-Login`. We require that header to match the allowlist.
/// `devMode` (local smoke tests only) allows header-less requests.
public struct AuthPolicy: Sendable {
    public let allowedLogins: Set<String>
    public let devMode: Bool

    public init(allowedLogins: Set<String>, devMode: Bool) {
        self.allowedLogins = Set(allowedLogins.map { $0.lowercased() })
        self.devMode = devMode
    }

    /// Parses a comma/space separated list such as "a@x.com, b@y.com".
    public init(allowedLoginsList: String, devMode: Bool) {
        let logins = allowedLoginsList
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0) }
            .filter { !$0.isEmpty }
        self.init(allowedLogins: Set(logins), devMode: devMode)
    }

    public func isAllowed(login: String?) -> Bool {
        guard let login, !login.isEmpty else { return devMode }
        return allowedLogins.contains(login.lowercased())
    }
}
