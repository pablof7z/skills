import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct PlaybackAdmissionTests {
    private let support = QueueStoreTests()

    @Test
    func storedBacklogDoesNotAutoplayWithoutAdmission() throws {
        let context = try makeContext(items: [("backlog", 10)])
        defer { context.cleanup() }

        context.controller.start()

        #expect(context.controller.currentItem == nil)
        #expect(try context.store.item(id: "backlog")?.status == .queued)
    }

    @Test
    func admissionTargetsExactNewItemInsteadOfOlderBacklog() throws {
        let context = try makeContext(items: [("old", 10), ("new", 20)])
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "new", requestedAtNanoseconds: 20)

        context.controller.start()

        #expect(context.controller.currentItem?.id == "new")
        #expect(try context.store.item(id: "old")?.status == .queued)
        #expect(try context.store.pendingPlaybackAdmissions().isEmpty)
    }

    @Test
    func admissionsAreIdempotentAndDeterministicallyOrdered() throws {
        let context = try makeContext(items: [("a", 10), ("b", 20)])
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "b", requestedAtNanoseconds: 20)
        let first = try context.store.admitPlayback(of: "a", requestedAtNanoseconds: 10)
        let duplicate = try context.store.admitPlayback(of: "a", requestedAtNanoseconds: 999)

        #expect(first == duplicate)
        #expect(try context.store.pendingPlaybackAdmissions().map(\.itemID) == ["a", "b"])
    }

    @Test
    func staleAdmissionDoesNotWedgeTheNextValidRequest() throws {
        let context = try makeContext(items: [("valid", 20)])
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "missing", requestedAtNanoseconds: 10)
        try context.store.admitPlayback(of: "valid", requestedAtNanoseconds: 20)

        #expect(try context.store.pendingPlaybackItem(heldItemID: nil)?.id == "valid")
        #expect(try context.store.pendingPlaybackAdmissions().map(\.itemID) == ["valid"])
    }

    @Test
    func visibleAskRetainsUnrelatedAdmission() throws {
        let context = try makeContext(items: [("speech", 10)])
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "speech", requestedAtNanoseconds: 10)

        #expect(try context.store.pendingPlaybackItem(heldItemID: "ask") == nil)
        #expect(try context.store.pendingPlaybackAdmissions().map(\.itemID) == ["speech"])
        #expect(try context.store.pendingPlaybackItem(heldItemID: nil)?.id == "speech")
    }

    @Test
    func globalPauseRetainsAdmissionUntilResume() throws {
        let context = try makeContext(items: [("waiting", 10)])
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "waiting", requestedAtNanoseconds: 10)
        try context.store.setGlobalPlaybackPaused(true)

        context.controller.start()
        #expect(context.controller.currentItem == nil)
        #expect(try context.store.pendingPlaybackAdmissions().map(\.itemID) == ["waiting"])

        context.controller.setGlobalPlaybackPaused(false)
        context.controller.refresh()
        #expect(context.controller.currentItem?.id == "waiting")
        #expect(try context.store.pendingPlaybackAdmissions().isEmpty)
    }

    @Test
    func anAdmissionCanBeClaimedOnlyOnce() throws {
        let context = try makeContext(items: [("once", 10)])
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "once", requestedAtNanoseconds: 10)

        #expect(try context.store.claimPlaybackItem(id: "once")?.id == "once")
        #expect(try context.store.claimPlaybackItem(id: "once") == nil)
    }

    @Test
    func explicitSelectionConsumesItsAutomaticAdmission() throws {
        let context = try makeContext(items: [("selected", 10)], outputIsMuted: true)
        defer { context.cleanup() }
        try context.store.admitPlayback(of: "selected", requestedAtNanoseconds: 10)
        let item = try #require(try context.store.item(id: "selected"))

        context.controller.start()
        context.controller.playNow(item)

        #expect(context.controller.currentItem?.id == "selected")
        #expect(try context.store.pendingPlaybackAdmissions().isEmpty)
    }

    private func makeContext(
        items: [(id: String, createdAt: Int64)],
        outputIsMuted: Bool = false
    ) throws -> PlaybackAdmissionContext {
        let directory = support.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.wav")
        try support.writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        for value in items {
            try store.save(support.item(
                id: value.id,
                createdAt: value.createdAt,
                outputFile: audio.path
            ))
        }
        let controller = PlaybackController(
            store: store,
            mediaController: support.disabledMediaController(stateDirectory: directory),
            outputIsMuted: { outputIsMuted }
        )
        return PlaybackAdmissionContext(
            directory: directory,
            store: store,
            controller: controller
        )
    }
}

@MainActor
private struct PlaybackAdmissionContext {
    let directory: URL
    let store: QueueStore
    let controller: PlaybackController

    func cleanup() {
        controller.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
