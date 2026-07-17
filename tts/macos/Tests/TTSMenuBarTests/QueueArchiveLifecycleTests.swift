import AVFAudio
import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct QueueArchiveLifecycleTests {
    private let support = QueueStoreTests()

    @Test
    func automaticEligibilityExcludesArchivedItemsAndArchivedParents() {
        let active = support.item(id: "active", createdAt: 30)
        var archived = support.item(id: "archived", createdAt: 10)
        archived.isArchived = true
        var parent = support.item(id: "parent", createdAt: 20)
        parent.isArchived = true
        var child = support.item(id: "child", createdAt: 21)
        child.parentItemID = parent.id
        child.attachmentID = "detail"
        let items = [archived, parent, child, active]

        #expect(PlaybackController.nextQueuedItem(in: items)?.id == active.id)
        #expect(!QueuePlaybackEligibility.isAutomaticallyPlayable(archived, in: items))
        #expect(!QueuePlaybackEligibility.isAutomaticallyPlayable(child, in: items))
        #expect(QueuePlaybackEligibility.allowsStart(archived, initiator: .direct, in: items))
    }

    @Test
    func batchArchiveIsAtomicAuditedAndCascadesToAttachments() throws {
        let directory = support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let parent = support.item(id: "parent", createdAt: 10)
        var child = support.item(id: "child", createdAt: 11)
        child.parentItemID = parent.id
        child.attachmentID = "detail"
        let other = support.item(id: "other", createdAt: 20)
        for item in [parent, child, other] { try store.save(item) }

        let updated = try store.setArchived(
            true,
            ids: [other.id, parent.id, parent.id],
            reason: "Bulk cleanup",
            actor: "test",
            now: 100
        )

        #expect(updated.map(\.id) == [child.id, other.id, parent.id])
        #expect(updated.allSatisfy { $0.archived && $0.status == .interrupted })
        #expect(updated.allSatisfy { $0.archivedAt == 100 && $0.archiveReason == "Bulk cleanup" })
        let operationURLs = try FileManager.default.contentsOfDirectory(
            at: store.operationsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(operationURLs.count == 1)
        let operation = try JSONDecoder().decode(
            QueueOperation.self,
            from: Data(contentsOf: try #require(operationURLs.first))
        )
        #expect(operation.kind == .archive)
        #expect(operation.sourceIDs == [child.id, other.id, parent.id])
    }

    @Test
    func batchArchiveValidatesEveryIDBeforeWriting() throws {
        let directory = support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let existing = support.item(id: "existing", createdAt: 10)
        try store.save(existing)

        #expect(throws: QueueOperationError.itemNotFound("missing")) {
            try store.setArchived(true, ids: [existing.id, "missing"])
        }

        #expect(try store.item(id: existing.id)?.archived == false)
        #expect(try FileManager.default.contentsOfDirectory(
            at: store.operationsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test
    func archivingCurrentAndQueuedItemsRetiresPlaybackWithoutAdvancing() throws {
        let context = try playbackContext(itemIDs: ["current", "next"], outputIsMuted: false)
        defer { context.cleanup() }
        context.controller.start()
        #expect(context.controller.currentItem?.id == "current")

        context.controller.setArchived(true, ids: ["current", "next"])

        #expect(context.controller.currentItem == nil)
        #expect(context.controller.player == nil)
        #expect(context.controller.nextQueuedItem == nil)
        let items = try context.store.loadItems()
        #expect(items.allSatisfy { $0.archived && $0.status == .interrupted })
    }

    @Test
    func externalArchiveReconciliationStopsCurrentPlayback() throws {
        let context = try playbackContext(itemIDs: ["current"], outputIsMuted: false)
        defer { context.cleanup() }
        context.controller.start()
        #expect(context.controller.currentItem?.id == "current")

        _ = try context.store.setArchived(true, id: "current", actor: "external")
        context.controller.refresh()

        #expect(context.controller.currentItem == nil)
        #expect(context.controller.player == nil)
        #expect(try context.store.item(id: "current")?.status == .interrupted)
    }

    @Test
    func explicitlyOpeningArchivedItemWhileMutedRemainsAllowedAndSilent() throws {
        let context = try playbackContext(itemIDs: ["archived"], outputIsMuted: true)
        defer { context.cleanup() }
        let archived = try context.store.setArchived(true, id: "archived", now: 100)
        context.controller.start()

        context.controller.playNow(archived)

        #expect(context.controller.currentItem?.id == archived.id)
        #expect(context.controller.currentItem?.archived == true)
        #expect(context.controller.currentItem?.status == .paused)
        #expect(context.controller.player?.isPlaying == false)
        context.controller.refresh()
        #expect(context.controller.currentItem?.id == archived.id)
    }

    @Test
    func archivedPendingAskDoesNotHoldTheQueue() {
        var ask = support.item(id: "ask", createdAt: 10)
        ask.kind = .question
        ask.questionStatus = .pending
        ask.isArchived = true

        let heldID = VisibleAskQueueHoldPolicy.heldItemID(
            isPlayerVisible: true,
            isWindowVisible: true,
            currentItem: ask,
            pendingPreviewItem: nil,
            lingeringItem: nil,
            hiddenItemID: nil
        )

        #expect(heldID == nil)
    }

    @Test
    func historyQueryTargetsEveryFilterMatchBeyondRenderLimit() {
        let now = Date(timeIntervalSince1970: 1_784_219_600)
        var items = (0 ..< 65).map { index -> TTSItem in
            var item = support.item(id: "match-\(index)", createdAt: Int64(now.timeIntervalSince1970))
            item.status = .played
            item.workspace = "/tmp/matching"
            return item
        }
        var hidden = support.item(id: "hidden", createdAt: Int64(now.timeIntervalSince1970))
        hidden.status = .played
        hidden.workspace = "/tmp/other"
        items.append(hidden)
        let query = PlayerHistoryQuery(
            isViewingArchive: false,
            entityFilters: HistoryEntityFilters(projects: ["matching"]),
            ageFilter: .today,
            hasInteractedWithHistory: false,
            searchQuery: "",
            now: now
        )

        let matches = PlayerHistoryFilterPolicy.filteredItems(in: items, query: query)

        #expect(matches.count == 65)
        #expect(!matches.contains { $0.id == hidden.id })
    }

    private func playbackContext(
        itemIDs: [String],
        outputIsMuted: Bool
    ) throws -> ArchivePlaybackContext {
        let directory = support.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.wav")
        try support.writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        for (index, id) in itemIDs.enumerated() {
            try store.save(support.item(id: id, createdAt: Int64(index + 1), outputFile: audio.path))
        }
        let controller = PlaybackController(
            store: store,
            mediaController: support.disabledMediaController(stateDirectory: directory),
            outputIsMuted: { outputIsMuted }
        )
        return ArchivePlaybackContext(directory: directory, store: store, controller: controller)
    }
}

@MainActor
private struct ArchivePlaybackContext {
    let directory: URL
    let store: QueueStore
    let controller: PlaybackController

    func cleanup() {
        controller.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
