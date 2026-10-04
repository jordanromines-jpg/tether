import Foundation
import TetherCore

/// Other Macs on the tailnet that might be running Tether (online macOS peers).
enum Peers {
    private static var cache: (at: Date, list: [[String: Any]])?
    private static let lock = NSLock()

    static var tailscalePath: String? {
        for p in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Tailscale's state for the Setup Assistant. Runs the CLI, so call it off the main thread.
    static func tailnetStatus() -> TailnetStatus {
        guard let path = tailscalePath else { return .unavailable }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return .unavailable }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return TailnetStatus.parse(data)
    }

    static func list() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < 30 { return cache.list }
        guard let path = tailscalePath else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [[String: Any]] = []
        func add(_ node: [String: Any], isSelf: Bool) {
            guard (node["OS"] as? String) == "macOS", isSelf || (node["Online"] as? Bool) == true,
                  let dns = (node["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !dns.isEmpty
            else { return }
            out.append(["name": node["HostName"] as? String ?? dns, "url": "https://\(dns)", "self": isSelf])
        }
        if let me = obj["Self"] as? [String: Any] { add(me, isSelf: true) }
        for peer in (obj["Peer"] as? [String: Any] ?? [:]).values {
            if let p = peer as? [String: Any] { add(p, isSelf: false) }
        }
        cache = (Date(), out)
        return out
    }

    /// "tailXXXX.ts.net"-style suffix of this Mac's tailnet, from its public URL.
    static func tailnetSuffix(publicURL: String?) -> String? {
        guard let host = publicURL.flatMap(URL.init(string:))?.host, let dot = host.firstIndex(of: ".") else { return nil }
        return String(host[host.index(after: dot)...])
    }
}
