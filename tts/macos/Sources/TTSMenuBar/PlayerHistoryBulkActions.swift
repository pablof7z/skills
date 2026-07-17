import AppKit

extension NowSpeakingPanelController {
    func matchingHistoryItems() -> [TTSItem] {
        PlayerHistoryFilterPolicy.filteredItems(
            in: playbackController.playerListItems,
            query: PlayerHistoryQuery(
                isViewingArchive: presentation.isViewingArchive,
                entityFilters: presentation.historyEntityFilters,
                ageFilter: presentation.historyAgeFilter,
                hasInteractedWithHistory: presentation.hasInteractedWithHistory,
                searchQuery: presentation.historySearchQuery,
                now: playbackController.historyTimestampClock.now
            )
        )
    }

    func updateBulkArchiveToolbarItem() {
        guard let item = historyBulkArchiveToolbarItem else { return }
        guard !presentation.isViewingArchive else {
            item.isEnabled = false
            item.toolTip = "Archive all matching is available in Recent history"
            return
        }
        let count = matchingHistoryItems().count
        item.isEnabled = count > 0
        item.toolTip = count == 1
            ? "Archive the item matching the current filters"
            : "Archive all \(count) items matching the current filters"
    }

    @objc func confirmArchiveAllMatching() {
        guard !presentation.isViewingArchive else { return }
        let itemIDs = matchingHistoryItems().map(\.id)
        guard !itemIDs.isEmpty else { return }

        let alert = NSAlert()
        let noun = itemIDs.count == 1 ? "item" : "items"
        alert.messageText = "Archive \(itemIDs.count) matching \(noun)?"
        alert.informativeText = "They’ll leave Recent history and won’t play automatically. You can restore them from Archived."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Archive \(itemIDs.count) \(noun.capitalized)")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            playbackController.setArchived(true, ids: itemIDs)
        }
    }
}
