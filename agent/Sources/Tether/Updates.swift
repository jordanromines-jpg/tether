import Foundation
import TetherCore

/// "Update available": once a day, one anonymous request to the GitHub API asks for the newest
/// commit on main and compares its date with this build's. Turn it off in the menu-bar panel.
final class Updates {
    static let shared = Updates()
    var onChange: () -> Void = {}
    private(set) var available = false
    private var timer: Timer?
    private var lastCheck: Date?

    func start() {
        timer?.invalidate()
        guard AppState.shared.checkUpdates else { available = false; onChange(); return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastCheck ?? .distantPast) > 86_400 else { return }
            self.check()
        }
    }

    func check() {
        guard AppState.shared.checkUpdates,
              let url = URL(string: "https://api.github.com/repos/\(BuildInfo.repo)/commits/main") else { return }
        lastCheck = Date()
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Tether", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }   // failures are silent
            let newer = UpdateCheck.isNewer(remote: UpdateCheck.latestCommitDate(data), build: BuildInfo.buildDate)
            DispatchQueue.main.async {
                self.available = newer
                self.onChange()
            }
        }.resume()
    }
}
