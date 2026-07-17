import AVFAudio
import Foundation
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    @Test @MainActor
    func manualPauseAndResumeReenterThePlaybackOwner() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try writeLongSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        try store.save(item(id: "owned", createdAt: 10, outputFile: audio.path))
        try store.admitPlayback(of: "owned", requestedAtNanoseconds: 10)
        let preferences = PlayerPreferencesStore(stateDirectory: directory)
        preferences.setPausesMedia(false)
        let logger = PlaybackOwnershipLogger()
        let mediaController = MediaController(
            preferencesStore: preferences,
            logger: logger
        )
        let controller = PlaybackController(
            store: store,
            mediaController: mediaController,
            outputIsMuted: { false }
        )
        defer { controller.shutdown() }

        controller.start()
        try await waitForPlaybackOwnership { controller.isAudioPlaying }
        let preparesBeforeResume = logger.records.count { $0.event == "prepare_skipped" }

        controller.togglePause()

        #expect(!controller.isAudioPlaying)
        #expect(logger.records.contains { $0.event == "resume_not_scheduled" })

        controller.togglePause()
        try await waitForPlaybackOwnership {
            logger.records.count { $0.event == "prepare_skipped" } > preparesBeforeResume
                && controller.isAudioPlaying
        }
    }

    private func writeLongSilentAudio(to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 40_000)
        )
        buffer.frameLength = 40_000
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @MainActor
    private func waitForPlaybackOwnership(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Playback ownership condition did not become true before timeout.")
    }
}

@MainActor
private final class PlaybackOwnershipLogger: MediaInterventionLogging {
    var records: [MediaInterventionRecord] = []

    func record(_ record: MediaInterventionRecord) {
        records.append(record)
    }
}
