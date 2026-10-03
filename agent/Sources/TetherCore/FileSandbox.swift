import Foundation

/// Restricts remote file browsing/downloads to a few folders, rejecting any path
/// (including via `..` or symlinks) that would escape them.
public struct FileSandbox: Sendable {
    public let roots: [String: URL]

    public init(roots: [String: URL]) {
        self.roots = roots.mapValues { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// Resolves `relativePath` inside the named root, or nil if it escapes or the root is unknown.
    public func resolve(root: String, relativePath: String) -> URL? {
        guard let base = roots[root] else { return nil }
        let cleaned = relativePath.split(separator: "/").filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
        let candidate = (cleaned.isEmpty ? base : base.appendingPathComponent(cleaned))
            .standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path == base.path || candidate.path.hasPrefix(basePath) else { return nil }
        return candidate
    }
}
