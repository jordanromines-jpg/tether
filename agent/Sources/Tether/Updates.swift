import Foundation
import TetherCore

/// "Update available": once a day, one anonymous request to the GitHub API compares this build's
/// commit with main (and lists what's new). Builds without a known commit compare dates instead.
/// Turn it off in the menu-bar panel.
final class Updates {
    static let shared = Updates()
    var onChange: () -> Void = {}
    private(set) var info: UpdateInfo?
    var available: Bool { info?.available ?? false }
    private var timer: Timer?
    private var lastCheck: Date?

    func start() {
        timer?.invalidate()
        guard AppState.shared.checkUpdates else { info = nil; onChange(); return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastCheck ?? .distantPast) > 86_400 else { return }
            self.check()
        }
    }

    func check() {
        guard AppState.shared.checkUpdates else { return }
        lastCheck = Date()
        let repo = BuildInfo.repo
        guard let commit = BuildInfo.commit,
              let url = URL(string: "https://api.github.com/repos/\(repo)/compare/\(commit)...main") else { checkByDate(); return }
        get(url) { [weak self] data, status in
            if status == 200, let info = UpdateCheck.compare(data) { self?.set(info) }
            else if status == 404 || status == 422 { self?.checkByDate() }   // a commit GitHub doesn't have
        }
    }

    private func checkByDate() {
        guard let url = URL(string: "https://api.github.com/repos/\(BuildInfo.repo)/commits/main") else { return }
        get(url) { [weak self] data, status in
            guard status == 200 else { return }
            let newer = UpdateCheck.isNewer(remote: UpdateCheck.latestCommitDate(data), build: BuildInfo.buildDate)
            self?.set(UpdateInfo(available: newer, count: 0, whatsNew: []))
        }
    }

    private func set(_ info: UpdateInfo) {
        DispatchQueue.main.async {
            self.info = info
            self.onChange()
        }
    }

    /// Failures are silent: no update banner is better than an error about GitHub.
    private func get(_ url: URL, done: @escaping (Data, Int) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Tether", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data, let status = (response as? HTTPURLResponse)?.statusCode else { return }
            done(data, status)
        }.resume()
    }
}
