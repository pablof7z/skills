import Foundation

extension QueueStore {
    @discardableResult
    func setArchived(
        _ archived: Bool,
        id: String,
        reason: String? = nil,
        actor: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> TTSItem {
        let updated = try setArchived(
            archived,
            ids: [id],
            reason: reason,
            actor: actor,
            now: now
        )
        guard let item = updated.first(where: { $0.id == id }) else {
            throw QueueOperationError.itemNotFound(id)
        }
        return item
    }

    @discardableResult
    func setArchived(
        _ archived: Bool,
        ids: [String],
        reason: String? = nil,
        actor: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> [TTSItem] {
        try withOperationsLock {
            let requestedIDs = Array(Set(ids)).sorted()
            guard !requestedIDs.isEmpty else { throw QueueOperationError.noSources }
            let allItems = try loadItemsUnlocked()
            let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
            for id in requestedIDs where itemsByID[id] == nil {
                throw QueueOperationError.itemNotFound(id)
            }

            let affectedIDs = Self.archiveAffectedIDs(
                requestedIDs: requestedIDs,
                allItems: allItems
            )
            let updated = affectedIDs.compactMap { id in
                itemsByID[id].map {
                    Self.applyingArchiveState(
                        archived,
                        to: $0,
                        reason: reason,
                        actor: actor,
                        now: now
                    )
                }
            }
            for item in updated { try saveUnlocked(item) }
            try saveOperation(QueueOperation(
                kind: archived ? .archive : .restore,
                sourceIDs: affectedIDs,
                replacementIDs: [],
                reason: reason,
                actor: actor,
                createdAt: now
            ))
            return updated
        }
    }

    static func applyingArchiveState(
        _ archived: Bool,
        to item: TTSItem,
        reason: String?,
        actor: String?,
        now: Int64
    ) -> TTSItem {
        var value = item
        value.isArchived = archived
        value.archivedAt = archived ? now : nil
        value.archiveReason = archived ? reason : nil
        value.archivedBy = archived ? actor : nil
        guard archived, [.queued, .playing, .paused].contains(value.status) else {
            return value
        }
        value.status = .interrupted
        value.completedAt = now
        value.playbackOffset = nil
        value.returnToPlaybackOffset = nil
        value.playbackInitiator = nil
        if !value.isAttachmentPlayback { value.isUnheard = true }
        return value
    }

    private static func archiveAffectedIDs(
        requestedIDs: [String],
        allItems: [TTSItem]
    ) -> [String] {
        var affected = Set(requestedIDs)
        var changed = true
        while changed {
            changed = false
            for item in allItems where item.isAttachmentPlayback {
                guard let parentID = item.parentItemID, affected.contains(parentID) else { continue }
                changed = affected.insert(item.id).inserted || changed
            }
        }
        return affected.sorted()
    }
}
