import AppKit
import Foundation

@MainActor
final class MediaController {
    private var pausedApps: [String] = []
    private var resumeTask: Task<Void, Never>?
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func pausePlayingApps() {
        guard mediaControlEnabled else { return }
        resumeTask?.cancel()
        resumeTask = nil
        let pausedNow = mediaApps.filter { app in
            guard appIsRunning(app), playerState(app) == "playing" else { return false }
            return runAppleScript("tell application \"\(escaped(app))\" to pause") != nil
        }
        for app in pausedNow where !pausedApps.contains(app) {
            pausedApps.append(app)
        }
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
                _ = runAppleScript("tell application \"\(escaped(app))\" to play")
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
            _ = runAppleScript("tell application \"\(escaped(app))\" to play")
        }
    }

    private var mediaControlEnabled: Bool {
        let value = environment["TTS_MEDIA_CONTROL"]?.lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    private var mediaApps: [String] {
        (environment["TTS_MEDIA_APPS"] ?? "Music,Spotify")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
