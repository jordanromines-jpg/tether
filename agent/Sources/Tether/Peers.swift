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

    /// Runs `tailscale status --json`; logs (once per distinct problem) when it fails.
    private nonisolated(unsafe) static var lastProblem = ""
    static func statusJSON() -> Data? {
        guard let path = tailscalePath else { note("no tailscale command found"); return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["status", "--json"]
        // The App Store Tailscale binary only acts as a command-line tool when it looks like it was
        // started from a shell (SHLVL is set); otherwise it tries to open its app and fails.
        var env = ProcessInfo.processInfo.environment
        env["SHLVL"] = env["SHLVL"] ?? "1"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { note("couldn't run \(path): \(error.localizedDescription)"); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        if proc.terminationStatus != 0 || data.isEmpty {
            note("tailscale status exited \(proc.terminationStatus): \(errText.prefix(300)) [stdout \(data.count) bytes]")
            return data.isEmpty ? nil : data
        }
        return data
    }
    private static func note(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        NSLog("Tether: \(problem)")
    }

    /// Tailscale's state for the Setup Assistant. Runs the CLI, so call it off the main thread.
    static func tailnetStatus() -> TailnetStatus {
        statusJSON().map(TailnetStatus.parse) ?? .unavailable
    }

    static func list() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < 30 { return cache.list }
        guard let data = statusJSON() else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            note("tailscale status wasn't JSON: \(String(decoding: data.prefix(200), as: UTF8.self))")
            return []
        }
        var out: [[String: Any]] = []
        // Offline Macs are listed too (with when they were last seen), so the picker can say
        // "Offline since…" rather than just leaving them out.
        func add(_ node: [String: Any], isSelf: Bool) {
            guard (node["OS"] as? String) == "macOS",
                  let dns = (node["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !dns.isEmpty
            else { return }
            let online = isSelf || (node["Online"] as? Bool) == true
            var entry: [String: Any] = ["name": node["HostName"] as? String ?? dns, "url": "https://\(dns)", "self": isSelf, "online": online]
            if !online, let seen = node["LastSeen"] as? String, !seen.hasPrefix("0001") { entry["lastSeen"] = seen }
            out.append(entry)
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
