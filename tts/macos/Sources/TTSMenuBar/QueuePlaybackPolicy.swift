import Foundation

struct QueuePlaybackPolicy {
    static func isActive(_ item: TTSItem, in items: [TTSItem]) -> Bool {
        let itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return isActive(item, itemsByID: itemsByID)
    }

    private static func isActive(_ item: TTSItem, itemsByID: [String: TTSItem]) -> Bool {
        var candidate = item
        var visited = Set<String>()
        while true {
            guard !candidate.archived, visited.insert(candidate.id).inserted else { return false }
            guard let parentID = candidate.parentItemID else { return true }
            guard let parent = itemsByID[parentID] else { return false }
            candidate = parent
        }
    }

    static func allowsStart(
        _ item: TTSItem,
        initiator: TTSPlaybackInitiator,
        in items: [TTSItem]
    ) -> Bool {
        guard item.status == .queued else { return false }
        return initiator == .direct || isActive(item, in: items)
    }

    static func isAutomaticallyPlayable(_ item: TTSItem, in items: [TTSItem]) -> Bool {
        allowsStart(item, initiator: .automatic, in: items)
    }

    static func nextQueuedItem(in items: [TTSItem]) -> TTSItem? {
        nextQueuedItem(in: items, where: { _ in true })
    }

    static func nextQueuedItem(
        in items: [TTSItem],
        where includes: @escaping (TTSItem) -> Bool
    ) -> TTSItem? {
        let itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let isPlayable = { (item: TTSItem) in
            includes(item)
                && item.status == .queued
                && isActive(item, itemsByID: itemsByID)
        }
        return items.first { $0.isAttachmentPlayback && isPlayable($0) }
            ?? items.first(where: isPlayable)
    }

    static func allowsCurrentPlayback(
        _ item: TTSItem,
        in items: [TTSItem],
        explicitlyOpenedInactiveItemID: String?
    ) -> Bool {
        isActive(item, in: items) || explicitlyOpenedInactiveItemID == item.id
    }
}

struct ManualQueuePauseBarrier {
    private var suppressedItemIDs: Set<String>

    init(itemsAtPause: [TTSItem]) {
        suppressedItemIDs = Set(itemsAtPause.map(\.id))
    }

    func allows(_ item: TTSItem) -> Bool {
        !suppressedItemIDs.contains(item.id)
    }

    func nextArrival(in items: [TTSItem]) -> TTSItem? {
        QueuePlaybackPolicy.nextQueuedItem(in: items, where: allows)
    }

    mutating func recordStarted(_ item: TTSItem) {
        suppressedItemIDs.insert(item.id)
    }
}
