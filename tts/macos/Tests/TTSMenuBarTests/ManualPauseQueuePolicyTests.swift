import AVFAudio
import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct ManualPauseQueuePolicyTests {
    private let support = QueueStoreTests()

    @Test
    func manualPauseCancelsWaitingAdmissionsAndLeavesBacklogInert() throws {
        let context = try makeContext(backlogIDs: ["old-a", "old-b"], admitBacklog: true)
        defer { context.cleanup() }

        context.pauseCurrent()
        context.controller.refresh()
        context.controller.refresh()

        #expect(context.controller.currentItem?.id == context.current.id)
        #expect(context.controller.currentItem?.status == .paused)
        #expect(try context.store.item(id: "old-a")?.status == .queued)
        #expect(try context.store.item(id: "old-b")?.status == .queued)
        #expect(try context.store.pendingPlaybackAdmissions().isEmpty)
    }

    @Test
    func newArrivalPlaysInsteadOfPrePauseBacklog() throws {
        let context = try makeContext(backlogIDs: ["old-a", "old-b"])
        defer { context.cleanup() }
        context.pauseCurrent()
        let arrival = support.item(id: "arrival", createdAt: 40, outputFile: context.audio.path)

        try context.store.save(arrival)
        try context.store.admitPlayback(of: arrival.id, requestedAtNanoseconds: 40)
        context.controller.refresh()

        #expect(context.controller.currentItem?.id == arrival.id)
        #expect(try context.store.item(id: "old-a")?.status == .queued)
        #expect(try context.store.item(id: "old-b")?.status == .queued)
        let parked = try #require(try context.store.item(id: context.current.id))
        #expect(parked.status == .interrupted)
        #expect(parked.unheard)
        #expect(parked.playbackOffset != nil)
    }

    @Test
    func arrivalCompletionDoesNotDrainPrePauseBacklog() throws {
        let context = try makeContext(backlogIDs: ["old"])
        defer { context.cleanup() }
        context.pauseCurrent()
        let arrival = support.item(id: "arrival", createdAt: 30, outputFile: context.audio.path)
        try context.store.save(arrival)
        try context.store.admitPlayback(of: arrival.id, requestedAtNanoseconds: 30)
        context.controller.refresh()
        let arrivalPlayer = try #require(context.controller.player)

        context.controller.audioPlayerDidFinishPlaying(arrivalPlayer, successfully: true)

        #expect(context.controller.currentItem == nil)
        #expect(try context.store.item(id: "old")?.status == .queued)
        #expect(try context.store.item(id: arrival.id)?.status == .played)
    }

    @Test
    func postPauseAdmissionsAdvanceInRequestOrder() throws {
        let context = try makeContext(backlogIDs: ["old"])
        defer { context.cleanup() }
        context.pauseCurrent()
        let first = support.item(id: "arrival-a", createdAt: 30, outputFile: context.audio.path)
        let second = support.item(id: "arrival-b", createdAt: 40, outputFile: context.audio.path)
        try context.store.save(first)
        try context.store.save(second)
        try context.store.admitPlayback(of: first.id, requestedAtNanoseconds: 30)
        try context.store.admitPlayback(of: second.id, requestedAtNanoseconds: 40)
        context.controller.refresh()
        let firstPlayer = try #require(context.controller.player)

        context.controller.audioPlayerDidFinishPlaying(firstPlayer, successfully: true)

        #expect(context.controller.currentItem?.id == second.id)
        let secondPlayer = try #require(context.controller.player)
        context.controller.audioPlayerDidFinishPlaying(secondPlayer, successfully: true)
        #expect(context.controller.currentItem == nil)
        #expect(try context.store.item(id: "old")?.status == .queued)
    }

    @Test
    func explicitResumeDoesNotReactivateStoredBacklog() throws {
        let context = try makeContext(backlogIDs: ["old"])
        defer { context.cleanup() }
        context.pauseCurrent()

        context.controller.togglePause()
        let resumedPlayer = try #require(context.controller.player)
        context.controller.audioPlayerDidFinishPlaying(resumedPlayer, successfully: true)

        #expect(context.controller.currentItem == nil)
        #expect(try context.store.item(id: "old")?.status == .queued)
    }

    @Test
    func stopDoesNotAdvanceExistingBacklog() throws {
        let context = try makeContext(backlogIDs: ["old"], admitBacklog: true)
        defer { context.cleanup() }

        context.controller.stop()

        #expect(context.controller.currentItem == nil)
        #expect(try context.store.item(id: "old")?.status == .queued)
        #expect(try context.store.item(id: context.current.id)?.status == .interrupted)
        #expect(try context.store.pendingPlaybackAdmissions().isEmpty)
    }

    private func makeContext(
        backlogIDs: [String],
        admitBacklog: Bool = false
    ) throws -> ManualPauseContext {
        let directory = support.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try support.writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        var current = support.item(id: "current", createdAt: 10, outputFile: audio.path)
        current.status = .playing
        current.startedAt = 10
        try store.save(current)
        var persistedItems = [current]
        for (index, id) in backlogIDs.enumerated() {
            let queued = support.item(
                id: id,
                createdAt: Int64(20 + index),
                outputFile: audio.path
            )
            try store.save(queued)
            if admitBacklog {
                try store.admitPlayback(
                    of: queued.id,
                    requestedAtNanoseconds: Int64(20 + index)
                )
            }
            persistedItems.append(queued)
        }
        let controller = PlaybackController(
            store: store,
            mediaController: support.disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false }
        )
        let player = try AVAudioPlayer(contentsOf: audio)
        #expect(player.play())
        controller.items = persistedItems
        controller.currentItemID = current.id
        controller.player = player
        controller.isAudioPlaying = true
        return ManualPauseContext(
            directory: directory,
            audio: audio,
            store: store,
            current: current,
            controller: controller
        )
    }
}

@MainActor
private struct ManualPauseContext {
    let directory: URL
    let audio: URL
    let store: QueueStore
    let current: TTSItem
    let controller: PlaybackController

    func pauseCurrent() {
        controller.togglePause()
        #expect(controller.currentItem?.status == .paused)
    }

    func cleanup() {
        controller.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
