import Darwin
import Foundation

extension QueueStore {
    var generationOwnersDirectory: URL {
        stateDirectory.appendingPathComponent("generation-owners", isDirectory: true)
    }

    func generationOwnerFile(for itemID: String) -> URL {
        generationOwnersDirectory.appendingPathComponent("\(itemID).owner")
    }

    @discardableResult
    func recoverOrphanedGeneratingItems(_ itemIDs: [String]) throws -> Int {
        try withOperationsLock {
            var recovered = 0
            let completedAt = Int64(Date().timeIntervalSince1970)
            for itemID in itemIDs {
                let ownerFile = generationOwnerFile(for: itemID)
                guard !Self.generationOwnerIsAlive(at: ownerFile) else { continue }
                guard var item = try itemUnlocked(id: itemID), item.status == .generating else { continue }

                item.status = .failed
                item.completedAt = completedAt
                item.error = "Speech generation stopped before audio was ready."
                try saveUnlocked(item)
                try? FileManager.default.removeItem(at: ownerFile)
                recovered += 1
            }
            return recovered
        }
    }

    static func generationOwnerIsAlive(at ownerFile: URL) -> Bool {
        guard let contents = try? String(contentsOf: ownerFile, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first,
              let ownerPID = Int32(String(firstLine)),
              ownerPID > 0 else { return false }
        return kill(ownerPID, 0) == 0 || errno == EPERM
    }
}
