import AppKit

extension NowSpeakingPanelController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        PlayerHistoryToolbarPolicy.rootItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        PlayerHistoryToolbarPolicy.allowedItemIdentifiers
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case PlayerHistoryToolbarPolicy.backItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Back"
            item.paletteLabel = "Back to Queue"
            item.image = NSImage(
                systemSymbolName: "chevron.left",
                accessibilityDescription: "Back to queue"
            )
            item.target = self
            item.action = #selector(navigateBackToHistory)
            item.toolTip = "Back to queue"
            item.isNavigational = true
            historyBackToolbarItem = item
            return item
        case PlayerHistoryToolbarPolicy.searchButtonItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search History"
            item.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "Search speech history"
            )
            item.target = self
            item.action = #selector(showHistorySearch)
            item.toolTip = "Search speech"
            return item
        case PlayerHistoryToolbarPolicy.searchFieldItemIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search History"
            item.searchField.placeholderString = "Search speech"
            item.searchField.target = self
            item.searchField.action = #selector(historySearchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.stringValue = presentation.historySearchQuery
            item.searchField.delegate = self
            item.searchField.setAccessibilityLabel("Search speech history")
            historySearchToolbarItem = item
            return item
        case PlayerHistoryToolbarPolicy.filterItemIdentifier:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.paletteLabel = "Filter History"
            item.image = NSImage(
                systemSymbolName: "line.3.horizontal.decrease",
                accessibilityDescription: "Filter history"
            )
            item.showsIndicator = true
            historyFilterToolbarItem = item
            updateHistoryFilterMenu()
            return item
        case PlayerHistoryToolbarPolicy.bulkArchiveItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Archive All Matching"
            item.paletteLabel = "Archive All Matching"
            item.image = NSImage(
                systemSymbolName: "archivebox",
                accessibilityDescription: "Archive all matching items"
            )
            item.target = self
            item.action = #selector(confirmArchiveAllMatching)
            historyBulkArchiveToolbarItem = item
            updateBulkArchiveToolbarItem()
            return item
        default:
            return nil
        }
    }
}
