import AppKit
import TetherCore

/// "Add a shortcut": a Finder alias to Tether.app in a folder the person picks (Applications by
/// default). Every alias is recorded in shortcuts.json so uninstall.sh removes exactly those.
enum Shortcuts {
    static let defaultFolder = URL(fileURLWithPath: "/Applications")
    private static var registryURL: URL { AppPaths.supportDirectory.appendingPathComponent("shortcuts.json") }

    static var registry: ShortcutRegistry {
        get { ShortcutRegistry(json: try? Data(contentsOf: registryURL)) }
        set { try? newValue.json.write(to: registryURL) }
    }

    enum Failure: LocalizedError {
        case notWritable(URL)
        case occupied(URL)
        var errorDescription: String? {
            switch self {
            case .notWritable(let f): "Tether can't add files to \(f.lastPathComponent). Choose another folder."
            case .occupied(let u): "There's already something called \(u.lastPathComponent) in \(u.deletingLastPathComponent().lastPathComponent)."
            }
        }
    }

    /// Creates (or refreshes) the alias and returns its location.
    @discardableResult
    static func addAlias(in folder: URL) throws -> URL {
        let app = Bundle.main.bundleURL
        let dest = folder.appendingPathComponent("Tether")
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable(folder) }
        if FileManager.default.fileExists(atPath: dest.path) {
            // Only ever replace an alias Tether made itself.
            guard registry.paths.contains(dest.path) else { throw Failure.occupied(dest) }
            try FileManager.default.removeItem(at: dest)
        }
        let data = try app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: dest)
        var r = registry
        r.add(dest.path)
        registry = r
        return dest
    }

    /// The menu-bar "Add a shortcut…" flow: pick a folder, make the alias, show it in Finder.
    static func addInteractively() {
        guard let folder = chooseFolder() else { return }
        do {
            let url = try addAlias(in: folder)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func chooseFolder() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Where should the Tether shortcut go?"
        panel.prompt = "Add shortcut here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultFolder
        return panel.runModal() == .OK ? panel.url : nil
    }
}
