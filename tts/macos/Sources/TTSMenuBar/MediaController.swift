import AppKit
import Foundation

@MainActor
final class MediaController {
    private var pausedApps: [String] = []
    private var resumeTask: Task<Void, Never>?
    private let preferencesStore: PlayerPreferencesStore

    init(preferencesStore: PlayerPreferencesStore) {
        self.preferencesStore = preferencesStore
    }

    func pausePlayingApps() -> Bool {
        guard mediaControlEnabled else { return false }
        resumeTask?.cancel()
        resumeTask = nil
        let pausedNow = mediaApps.filter { app in
            guard appIsRunning(app), playerState(app) == "playing" else { return false }
            return runAppleScriptCommand("tell application \"\(escaped(app))\" to pause")
        }
        for app in pausedNow where !pausedApps.contains(app) {
            pausedApps.append(app)
        }
        return !pausedNow.isEmpty
    }

    func resumePausedApps(after delay: TimeInterval) {
        resumeTask?.cancel()
        guard !pausedApps.isEmpty else { return }

        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let apps = pausedApps
            pausedApps = []
            for app in apps where appIsRunning(app) {
                _ = runAppleScriptCommand("tell application \"\(escaped(app))\" to play")
            }
            resumeTask = nil
        }
    }

    func resumePausedAppsImmediately() {
        resumeTask?.cancel()
        resumeTask = nil
        let apps = pausedApps
        pausedApps = []
        for app in apps where appIsRunning(app) {
            _ = runAppleScriptCommand("tell application \"\(escaped(app))\" to play")
        }
    }

    var mediaHandoffDelay: TimeInterval {
        preferencesStore.preferences.mediaHandoffDelay
    }

    var mediaResumeDelay: TimeInterval {
        preferencesStore.preferences.mediaResumeDelay
    }

    private var mediaControlEnabled: Bool {
        preferencesStore.preferences.pausesMedia
    }

    private var mediaApps: [String] {
        ["Music", "Spotify"]
    }

    private func appIsRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == name
        }
    }

    private func playerState(_ app: String) -> String? {
        runAppleScript("tell application \"\(escaped(app))\" to player state as string")
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result?.stringValue
    }

    private func runAppleScriptCommand(_ source: String) -> Bool {
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
