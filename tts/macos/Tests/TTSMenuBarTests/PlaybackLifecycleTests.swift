import AVFAudio
import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct PlaybackLifecycleTests {
    private let support = QueueStoreTests()

    @Test
    func recoveredManualPauseDoesNotBecomeAutoplayWork() throws {
        let directory = support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.mp3")
        try Data("audio".utf8).write(to: audio)
        let store = QueueStore(stateDirectory: directory)
        var interrupted = support.item(id: "active", createdAt: 10, outputFile: audio.path)
        interrupted.status = .paused
        interrupted.startedAt = 11
        try store.save(interrupted)

        try store.recoverInterruptedItems()

        let recovered = try #require(store.loadItems().first)
        #expect(recovered.status == .interrupted)
        #expect(recovered.startedAt == 11)
        #expect(recovered.completedAt != nil)
        #expect(recovered.unheard)
    }

    @Test
    func recoversCrashedPlayingItemIntoQueue() throws {
        let directory = support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.mp3")
        try Data("audio".utf8).write(to: audio)
        let store = QueueStore(stateDirectory: directory)
        var playing = support.item(id: "active", createdAt: 10, outputFile: audio.path)
        playing.status = .playing
        playing.startedAt = 11
        try store.save(playing)

        try store.recoverInterruptedItems()

        let recovered = try #require(store.loadItems().first)
        #expect(recovered.status == .queued)
        #expect(recovered.startedAt == nil)
    }

    @Test
    func orderlyShutdownParksCurrentItemAndRestartStaysIdle() throws {
        let directory = support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.wav")
        try support.writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        var current = support.item(id: "active", createdAt: 10, outputFile: audio.path)
        current.status = .playing
        current.startedAt = 11
        try store.save(current)
        let controller = makeController(store: store, directory: directory)
        let player = try AVAudioPlayer(contentsOf: audio)
        player.currentTime = 0.05
        controller.items = [current]
        controller.currentItemID = current.id
        controller.player = player

        controller.shutdown()

        let parked = try #require(try store.item(id: current.id))
        #expect(parked.status == .interrupted)
        #expect(parked.unheard)
        #expect(abs((parked.playbackOffset ?? 0) - 0.05) < 0.01)
        #expect(parked.completedAt != nil)

        let restarted = makeController(store: store, directory: directory)
        restarted.start()
        #expect(restarted.currentItem == nil)
        #expect(try store.item(id: current.id)?.status == .interrupted)
        restarted.shutdown()
    }

    private func makeController(store: QueueStore, directory: URL) -> PlaybackController {
        PlaybackController(
            store: store,
            mediaController: support.disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false }
        )
    }
}
