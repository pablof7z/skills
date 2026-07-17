import Foundation

enum VisibleAskQueueHoldPolicy {
    static func heldItemID(
        isPlayerVisible: Bool,
        isWindowVisible: Bool,
        currentItem: TTSItem?,
        pendingPreviewItem: TTSItem?,
        lingeringItem: TTSItem?,
        hiddenItemID: String?
    ) -> String? {
        guard isPlayerVisible, isWindowVisible else { return nil }
        let displayedItem = PlayerContentSelection.displayedItem(
            currentItem: currentItem,
            pendingPreviewItem: pendingPreviewItem,
            lingeringItem: lingeringItem
        )
        guard let displayedItem,
              displayedItem.isPendingQuestion,
              PlayerNavigationPolicy.shouldDisplay(
                  itemID: displayedItem.id,
                  hiddenItemID: hiddenItemID
              )
        else {
            return nil
        }
        return displayedItem.id
    }
}
