import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct MutedPlaybackNavigationTests {
    private let support = QueueStoreTests()

    @Test
    func explicitQueueSelectionOpensPausedAndDoesNotDuplicateItem() throws {
        let context = try makeContext(itemID: "selected")
        defer { context.cleanup() }
        try context.store.setGlobalPlaybackPaused(true)
        var outputIsMuted = true
        let controller = context.controller(outputIsMuted: { outputIsMuted })
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(context.item)

        #expect(!controller.isGloballyPaused)
        #expect(!context.store.isGlobalPlaybackPaused())
        #expect(controller.currentItem?.id == context.item.id)
        #expect(controller.currentItem?.status == .paused)
        #expect(controller.player?.isPlaying == false)
        #expect(try context.store.loadItems().map(\.id) == [context.item.id])
        #expect(try context.store.loadItems().map(\.status) == [.paused])

        controller.playNow(try #require(controller.currentItem))
        #expect(controller.currentItem?.status == .paused)
        #expect(controller.player?.isPlaying == false)

        outputIsMuted = false
        controller.refresh()
        #expect(controller.currentItem?.status == .playing)
    }

    @Test
    func explicitRecentSelectionOpensTheOriginalItemPaused() throws {
        var context = try makeContext(itemID: "recent")
        defer { context.cleanup() }
        context.item.status = .played
        try context.store.save(context.item)
        let controller = context.controller(outputIsMuted: { true })
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(context.item)

        let items = try context.store.loadItems()
        #expect(items.count == 1)
        #expect(items.first?.id == context.item.id)
        #expect(items.first?.createdAt == context.item.createdAt)
        #expect(items.first?.status == .paused)
        #expect(controller.currentItem?.id == context.item.id)
        #expect(controller.player?.isPlaying == false)
    }

    private func makeContext(itemID: String) throws -> TestContext {
        let directory = support.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.wav")
        try support.writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        let item = support.item(id: itemID, createdAt: 10, outputFile: audio.path)
        try store.save(item)
        return TestContext(directory: directory, store: store, item: item, support: support)
    }
}

@MainActor
private struct TestContext {
    let directory: URL
    let store: QueueStore
    var item: TTSItem
    let support: QueueStoreTests

    func controller(outputIsMuted: @escaping () -> Bool) -> PlaybackController {
        PlaybackController(
            store: store,
            mediaController: support.disabledMediaController(stateDirectory: directory),
            outputIsMuted: outputIsMuted
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
