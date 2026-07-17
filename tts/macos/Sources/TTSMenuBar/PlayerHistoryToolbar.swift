import AppKit

extension NowSpeakingPanelController {
    func configureHistoryToolbar() {
        let toolbar = NSToolbar(identifier: PlayerHistoryToolbarPolicy.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        panel.toolbarStyle = .unified
        panel.toolbar = toolbar
    }

    func updateHistoryNavigation() {
        guard let toolbar = panel.toolbar else { return }
        let itemID = playbackController.currentItem?.id
            ?? presentation.pendingPreviewItem?.id
            ?? presentation.lingeringItem?.id
        let shouldShowBack = PlayerNavigationPolicy.shouldDisplay(
            itemID: itemID,
            hiddenItemID: presentation.hiddenItemID
        )
        let backIndex = toolbar.items.firstIndex {
            $0.itemIdentifier == PlayerHistoryToolbarPolicy.backItemIdentifier
        }
        if shouldShowBack, backIndex == nil {
            toolbar.insertItem(withItemIdentifier: PlayerHistoryToolbarPolicy.backItemIdentifier, at: 0)
        } else if !shouldShowBack, let backIndex {
            toolbar.removeItem(at: backIndex)
            historyBackToolbarItem = nil
        }
    }

    @objc func navigateBackToHistory() {
        dismissPlayerContent()
    }

    func updateHistoryFilterMenu() {
        guard let item = historyFilterToolbarItem else { return }
        let historyItems = presentation.isViewingArchive
            ? playbackController.archivedHistoryItems
            : playbackController.activeHistoryItems
        let projects = PlayerHistoryFilterPolicy.availableProjects(
            in: historyItems,
            ageFilter: presentation.historyAgeFilter,
            hasInteractedWithHistory: presentation.hasInteractedWithHistory,
            searchQuery: presentation.historySearchQuery,
            now: playbackController.historyTimestampClock.now
        )
        if let selected = presentation.historyProjectFilter, !projects.contains(selected) {
            presentation.historyProjectFilter = nil
        }

        let menu = NSMenu(title: "Filter History")
        let recentItems = NSMenuItem(
            title: "Recent",
            action: #selector(selectHistoryArchive(_:)),
            keyEquivalent: ""
        )
        recentItems.target = self
        recentItems.representedObject = false
        recentItems.state = presentation.isViewingArchive ? .off : .on
        recentItems.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(recentItems)

        let archivedItems = NSMenuItem(
            title: "Archived",
            action: #selector(selectHistoryArchive(_:)),
            keyEquivalent: ""
        )
        archivedItems.target = self
        archivedItems.representedObject = true
        archivedItems.state = presentation.isViewingArchive ? .on : .off
        archivedItems.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        menu.addItem(archivedItems)
        menu.addItem(.separator())

        menu.addItem(historyAgeFilterMenuItem)
        menu.addItem(projectFilterMenuItem(projects: projects))
        item.menu = menu
        let scope = presentation.isViewingArchive ? "Archived" : "Recent"
        item.toolTip = presentation.historyProjectFilter.map {
            "\(scope) history in \($0)"
        } ?? "\(scope) history in all projects"
    }

    private var historyAgeFilterMenuItem: NSMenuItem {
        let submenu = NSMenu(title: "Hide items older than")
        for filter in HistoryAgeFilter.allCases {
            let ageItem = NSMenuItem(
                title: filter.title,
                action: #selector(selectHistoryAgeFilter(_:)),
                keyEquivalent: ""
            )
            ageItem.target = self
            ageItem.representedObject = filter
            ageItem.state = presentation.historyAgeFilter == filter ? .on : .off
            submenu.addItem(ageItem)
        }
        let item = NSMenuItem(title: "Hide items older than", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func projectFilterMenuItem(projects: [String]) -> NSMenuItem {
        let submenu = NSMenu(title: "Projects")
        let allProjects = NSMenuItem(
            title: "All Projects",
            action: #selector(selectHistoryProject(_:)),
            keyEquivalent: ""
        )
        allProjects.target = self
        allProjects.state = presentation.historyProjectFilter == nil ? .on : .off
        submenu.addItem(allProjects)
        if !projects.isEmpty {
            submenu.addItem(.separator())
        }
        for project in projects {
            let projectItem = NSMenuItem(
                title: project,
                action: #selector(selectHistoryProject(_:)),
                keyEquivalent: ""
            )
            projectItem.target = self
            projectItem.representedObject = project
            projectItem.state = presentation.historyProjectFilter == project ? .on : .off
            submenu.addItem(projectItem)
        }
        let item = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc func selectHistoryProject(_ sender: NSMenuItem) {
        presentation.registerHistoryInteraction()
        presentation.historyProjectFilter = sender.representedObject as? String
        updateHistoryFilterMenu()
    }

    @objc func selectHistoryArchive(_ sender: NSMenuItem) {
        presentation.registerHistoryInteraction()
        presentation.isViewingArchive = (sender.representedObject as? Bool) == true
        updateHistoryFilterMenu()
    }

    @objc func selectHistoryAgeFilter(_ sender: NSMenuItem) {
        guard let filter = sender.representedObject as? HistoryAgeFilter else { return }
        presentation.registerHistoryInteraction()
        presentation.historyAgeFilter = filter
        updateHistoryFilterMenu()
    }

    @objc func showHistorySearch() {
        presentation.showHistorySearch()
    }

    @objc func historySearchChanged(_ sender: NSSearchField) {
        presentation.registerHistoryInteraction()
        presentation.historySearchQuery = sender.stringValue
    }

    func updateHistorySearchToolbar() {
        guard let toolbar = panel.toolbar else { return }
        let searchIDs = [
            PlayerHistoryToolbarPolicy.searchButtonItemIdentifier,
            PlayerHistoryToolbarPolicy.searchFieldItemIdentifier,
        ]
        guard let index = toolbar.items.firstIndex(where: { searchIDs.contains($0.itemIdentifier) }) else {
            return
        }
        let expected = presentation.isHistorySearchVisible
            ? PlayerHistoryToolbarPolicy.searchFieldItemIdentifier
            : PlayerHistoryToolbarPolicy.searchButtonItemIdentifier
        guard toolbar.items[index].itemIdentifier != expected else { return }

        toolbar.removeItem(at: index)
        historySearchToolbarItem = nil
        toolbar.insertItem(withItemIdentifier: expected, at: index)
        guard presentation.isHistorySearchVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.historySearchToolbarItem?.searchField)
        }
    }

}

extension NowSpeakingPanelController: NSSearchFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field.stringValue.isEmpty
        else {
            return
        }
        presentation.hideHistorySearch()
    }
}
