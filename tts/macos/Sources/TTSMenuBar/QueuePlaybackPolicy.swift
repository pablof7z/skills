import Foundation

struct QueuePlaybackPolicy {
    static func nextQueuedItem(in items: [TTSItem]) -> TTSItem? {
        items.first { $0.status == .queued && $0.isAttachmentPlayback }
            ?? items.first { $0.status == .queued }
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
        QueuePlaybackPolicy.nextQueuedItem(
            in: items.filter { allows($0) }
        )
    }

    mutating func recordStarted(_ item: TTSItem) {
        suppressedItemIDs.insert(item.id)
    }
}
