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
                contentIdentifier: nil,
                title: nil,
                artist: nil,
                album: nil,
                isPlaying: state == "playing"
            )
        }
    }

    func pause(_ session: MediaSessionSnapshot) async throws -> Bool {
        try run(command: "pause", session: session)
    }

    func play(_ session: MediaSessionSnapshot) async throws -> Bool {
        try run(command: "play", session: session)
    }

    private func playerState(_ bundleIdentifier: String) -> String? {
        var error: NSDictionary?
        let source = "tell application id \"\(escaped(bundleIdentifier))\" to player state as string"
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("AppleScript media state failed: %@", error)
            return nil
        }
        return result?.stringValue
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
