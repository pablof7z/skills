import Foundation
import MediaPlayer
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct MediaRemoteRuntimeTests {
    @Test
    func silentNowPlayingSessionAcceptsVerifiedPauseAndPlay() async throws {
        guard ProcessInfo.processInfo.environment["TTS_MEDIAREMOTE_INTEGRATION"] == "1" else {
            return
        }
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = packageDirectory.appendingPathComponent("Resources/tts-media-remote.pl")
        let library = packageDirectory.appendingPathComponent(
            ".build/debug/libTTSMediaRemoteAdapter.dylib"
        )
        #expect(FileManager.default.fileExists(atPath: library.path))
        let backend = MediaRemoteControlBackend(scriptURL: script, libraryURL: library)

        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Codex Silent Runtime Fixture",
            MPMediaItemPropertyArtist: "TTS Tests",
            MPNowPlayingInfoPropertyExternalContentIdentifier: "tts-runtime-fixture",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        nowPlaying.playbackState = .playing
        let commands = MPRemoteCommandCenter.shared()
        let pauseTarget = commands.pauseCommand.addTarget { _ in
            nowPlaying.playbackState = .paused
            var info = nowPlaying.nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            nowPlaying.nowPlayingInfo = info
            return .success
        }
        let playTarget = commands.playCommand.addTarget { _ in
            nowPlaying.playbackState = .playing
            var info = nowPlaying.nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            nowPlaying.nowPlayingInfo = info
            return .success
        }
        defer {
            commands.pauseCommand.removeTarget(pauseTarget)
            commands.playCommand.removeTarget(playTarget)
            nowPlaying.playbackState = .stopped
            nowPlaying.nowPlayingInfo = nil
        }

        let playing = try await waitForSession(backend, playing: true)
        #expect(try await backend.pause(playing))
        let paused = try await waitForSession(backend, playing: false)
        #expect(paused.belongsToSameSession(as: playing))
        #expect(try await backend.play(paused))
        _ = try await waitForSession(backend, playing: true)
    }

    private func waitForSession(
        _ backend: MediaRemoteControlBackend,
        playing: Bool
    ) async throws -> MediaSessionSnapshot {
        for _ in 0..<30 {
            if let session = try await backend.sessions().first,
               session.isPlaying == playing {
                return session
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("MediaRemote did not report playing=\(playing) before timeout.")
        throw MediaControlBackendError.commandFailed("Runtime state did not converge.")
    }
}
