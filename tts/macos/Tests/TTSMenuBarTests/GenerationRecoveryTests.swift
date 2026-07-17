import Darwin
import Foundation
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    @Test
    func keepsGeneratingItemWhileOwnerProcessIsAlive() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var generating = item(id: "active-generation", createdAt: 10)
        generating.status = .generating
        try store.save(generating)
        try writeGenerationOwner(getpid(), itemID: generating.id, store: store)

        #expect(try store.recoverOrphanedGeneratingItems([generating.id]) == 0)
        #expect(try store.item(id: generating.id)?.status == .generating)
    }

    @Test
    func failsGeneratingItemWhenOwnerProcessEnded() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var generating = item(id: "dead-generation", createdAt: 10)
        generating.status = .generating
        try store.save(generating)
        try writeGenerationOwner(Int32.max, itemID: generating.id, store: store)

        #expect(try store.recoverOrphanedGeneratingItems([generating.id]) == 1)
        let recovered = try #require(try store.item(id: generating.id))
        #expect(recovered.status == .failed)
        #expect(recovered.error == "Speech generation stopped before audio was ready.")
        #expect(recovered.completedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: store.generationOwnerFile(for: generating.id).path))
    }

    @Test
    func failsLegacyGeneratingItemWithoutOwnerLease() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var generating = item(id: "legacy-generation", createdAt: 10)
        generating.status = .generating
        try store.save(generating)

        #expect(try store.recoverOrphanedGeneratingItems([generating.id]) == 1)
        #expect(try store.item(id: generating.id)?.status == .failed)
    }

    func writeGenerationOwner(_ pid: Int32, itemID: String, store: QueueStore) throws {
        try FileManager.default.createDirectory(
            at: store.generationOwnersDirectory,
            withIntermediateDirectories: true
        )
        try Data("\(pid)\n10\n".utf8).write(to: store.generationOwnerFile(for: itemID))
    }
}
