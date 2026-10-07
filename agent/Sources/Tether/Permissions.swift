import ApplicationServices
import CoreGraphics
import Foundation

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var downloadsURL: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    static var desktopURL: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
    static var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Listing a protected folder asks macOS for access the first time (a one-time "Allow" prompt
    /// on the Mac). Until someone answers, that call BLOCKS — so it only ever runs on a background
    /// thread, and everything else reads the cached result.
    private static let folderLock = NSLock()
    nonisolated(unsafe) private static var folderAccess: [String: Bool] = [:]
    nonisolated(unsafe) private static var checking = false

    static func refreshFolderAccess() {
        folderLock.lock()
        if checking { folderLock.unlock(); return }
        checking = true
        folderLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let result = [
                "downloads": (try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)) != nil,
                "desktop": (try? FileManager.default.contentsOfDirectory(atPath: desktopURL.path)) != nil,
                "documents": (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) != nil,
            ]
            folderLock.lock(); folderAccess = result; checking = false; folderLock.unlock()
        }
    }

    /// Cached answer for "downloads"/"desktop": true, false, or nil while macOS is still asking.
    static func folderAllowed(_ root: String) -> Bool? {
        folderLock.lock(); defer { folderLock.unlock() }
        return folderAccess[root]
    }

    static var json: [String: Any] {
        folderLock.lock(); let folders = folderAccess; folderLock.unlock()
        if folders.values.contains(false) || folders.isEmpty { refreshFolderAccess() }
        var out: [String: Any] = ["screen": screenRecording, "input": accessibility]
        for key in ["downloads", "desktop", "documents"] { out[key] = folders[key].map { $0 as Any } ?? "pending" }
        return out
    }

    /// Shows the system prompts (once each) for anything missing.
    static func requestMissing() {
        // Trigger the Files & Folders prompts now (off the main thread), while someone is at the Mac.
        refreshFolderAccess()
        if !screenRecording { _ = CGRequestScreenCaptureAccess() }
        if !accessibility {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }
}
