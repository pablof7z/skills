import Foundation

@MainActor
final class MediaRemoteControlBackend: MediaControlBackend {
    let name = "MediaRemote"
    private let scriptURL: URL
    private let libraryURL: URL

    init(scriptURL: URL, libraryURL: URL) {
        self.scriptURL = scriptURL
        self.libraryURL = libraryURL
    }

    static func bundled() -> MediaRemoteControlBackend? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("tts-media-remote.pl")
        let library = resources.appendingPathComponent("libTTSMediaRemoteAdapter.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: library.path) else {
            return nil
        }
        return MediaRemoteControlBackend(scriptURL: script, libraryURL: library)
    }

    func sessions() async throws -> [MediaSessionSnapshot] {
        let output = try await run(command: "get")
        guard output != "null", !output.isEmpty else { return [] }
        let data = Data(output.utf8)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let contentIdentifier = payload.contentItemIdentifier
            ?? payload.uniqueIdentifier
            ?? Self.fallbackContentIdentifier(payload)
        return [MediaSessionSnapshot(
            bundleIdentifier: payload.bundleIdentifier,
            processIdentifier: payload.processIdentifier,
            contentIdentifier: contentIdentifier,
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            isPlaying: payload.playing
        )]
    }

    func pause(_: MediaSessionSnapshot) async throws -> Bool {
        try await send(command: "pause")
    }

    func play(_: MediaSessionSnapshot) async throws -> Bool {
        try await send(command: "play")
    }

    private func send(command: String) async throws -> Bool {
        let output = try await run(command: command)
        let result = try JSONDecoder().decode(CommandResult.self, from: Data(output.utf8))
        return result.accepted
    }

    private func run(command: String) async throws -> String {
        let scriptPath = scriptURL.path
        let libraryPath = libraryURL.path
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptPath, libraryPath, command]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw MediaControlBackendError.unavailable(error.localizedDescription)
            }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let reason = String(data: errorOutput, encoding: .utf8)
                    ?? "MediaRemote helper exited with status \(process.terminationStatus)."
                throw MediaControlBackendError.commandFailed(reason)
            }
            return String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }

    private static func fallbackContentIdentifier(_ payload: Payload) -> String? {
        let parts = [payload.title, payload.artist, payload.album].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\u{1F}")
    }

    private struct Payload: Decodable {
        let bundleIdentifier: String?
        let processIdentifier: Int32?
        let contentItemIdentifier: String?
        let uniqueIdentifier: String?
        let title: String?
        let artist: String?
        let album: String?
        let playing: Bool
    }

    private struct CommandResult: Decodable {
        let accepted: Bool
    }
}
