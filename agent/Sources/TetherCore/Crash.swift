import Foundation

/// A crash report macOS wrote for Tether (~/Library/Logs/DiagnosticReports/Tether-*.ips), boiled
/// down to what a bug report needs. Nothing here is sent anywhere: the panel offers to open a
/// pre-filled GitHub issue that the person reads and submits themselves.
public struct CrashSummary: Equatable {
    public let date: Date?
    public let os: String
    public let exception: String
    /// The frames nearest the crash, Tether's own first (system frames rarely say what went wrong).
    public let frames: [String]

    /// Parses an .ips file: one JSON header line, then the JSON report.
    public static func parse(_ data: Data) -> CrashSummary? {
        guard let text = String(data: data, encoding: .utf8), let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        let stamp = header["timestamp"] as? String ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        let os = header["os_version"] as? String ?? ""
        let exc = body["exception"] as? [String: Any] ?? [:]
        let exception = [exc["type"] as? String, exc["signal"] as? String].compactMap { $0 }.joined(separator: " ")
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { ($0["triggered"] as? Bool) == true } ?? threads.first ?? [:]
        let all = (crashed["frames"] as? [[String: Any]] ?? []).map { f -> (image: String, text: String) in
            let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            let symbol = f["symbol"] as? String ?? "0x\(String(f["imageOffset"] as? Int ?? 0, radix: 16))"
            // File name only: full paths would include the builder's home folder.
            let place = (f["sourceFile"] as? String).map { " (\(URL(fileURLWithPath: $0).lastPathComponent):\(f["sourceLine"] as? Int ?? 0))" } ?? ""
            return (image, "\(image): \(symbol)\(place)")
        }
        let own = all.filter { $0.image == "Tether" }
        let frames = (own.isEmpty ? all : own).prefix(8).map(\.text)
        return CrashSummary(date: formatter.date(from: stamp), os: os, exception: exception.isEmpty ? "unknown" : exception, frames: Array(frames))
    }

    /// The body of a GitHub issue: no logins, emails or paths beyond the frame names.
    public func issueBody(version: String) -> String {
        let when = date.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return """
        **What happened:** Tether quit unexpectedly.

        - Tether version: \(version)
        - macOS: \(os)
        - When: \(when)
        - Exception: \(exception)

        Nearest frames:
        ```
        \(frames.joined(separator: "\n"))
        ```

        **What I was doing:** (please describe)
        """
    }
}
