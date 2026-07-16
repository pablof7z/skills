import AppKit
import Foundation

@MainActor
final class AppleScriptMediaControlBackend: MediaControlBackend {
    let name = "AppleScript"
    private let applications = [
        "com.apple.Music",
        "com.spotify.client",
    ]

    func sessions() async throws -> [MediaSessionSnapshot] {
        applications.compactMap { bundleIdentifier in
            guard let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first,
            let state = playerState(bundleIdentifier) else {
                return nil
            }
            return MediaSessionSnapshot(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: app.processIdentifier,
                contentIdentifier: state.contentIdentifier,
                title: nil,
                artist: nil,
                album: nil,
                isPlaying: state.playerState == "playing"
            )
        }
    }

    func pause(_ session: MediaSessionSnapshot) async throws -> Bool {
        try run(command: "pause", session: session)
    }

    func play(_ session: MediaSessionSnapshot) async throws -> Bool {
        try run(command: "play", session: session)
    }

    func restoreOnShutdown(_ session: MediaSessionSnapshot) -> Bool {
        guard let bundleIdentifier = session.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
              ).first,
              app.processIdentifier == session.processIdentifier,
              let current = snapshot(bundleIdentifier: bundleIdentifier, app: app),
              current.belongsToSameSession(as: session),
              !current.isPlaying else {
            return false
        }
        return (try? run(command: "play", session: current)) == true
    }

    private func playerState(
        _ bundleIdentifier: String
    ) -> (playerState: String, contentIdentifier: String)? {
        var error: NSDictionary?
        let identifier = bundleIdentifier == "com.apple.Music"
            ? "persistent ID of current track as string"
            : "id of current track as string"
        let source = "tell application id \"\(escaped(bundleIdentifier))\" to "
            + "(player state as string) & linefeed & (\(identifier))"
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("AppleScript media state failed: %@", error)
            return nil
        }
        guard let value = result?.stringValue else { return nil }
        let parts = value.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private func snapshot(
        bundleIdentifier: String,
        app: NSRunningApplication
    ) -> MediaSessionSnapshot? {
        guard let state = playerState(bundleIdentifier) else { return nil }
        return MediaSessionSnapshot(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: app.processIdentifier,
            contentIdentifier: state.contentIdentifier,
            title: nil,
            artist: nil,
            album: nil,
            isPlaying: state.playerState == "playing"
        )
    }

    private func run(command: String, session: MediaSessionSnapshot) throws -> Bool {
        guard let bundleIdentifier = session.bundleIdentifier else { return false }
        var error: NSDictionary?
        let source = "tell application id \"\(escaped(bundleIdentifier))\" to \(command)"
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("AppleScript media command failed: %@", error)
            throw MediaControlBackendError.commandFailed(error.description)
        }
        return true
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
