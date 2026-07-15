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
        let projects = Array(Set(playbackController.playerListItems.compactMap(\.workspaceName))).sorted()
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

        let projectsHeader = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        projectsHeader.isEnabled = false
        menu.addItem(projectsHeader)
        let allProjects = NSMenuItem(
            title: "All Projects",
            action: #selector(selectHistoryProject(_:)),
            keyEquivalent: ""
        )
        allProjects.target = self
        allProjects.state = presentation.historyProjectFilter == nil ? .on : .off
        menu.addItem(allProjects)
        if !projects.isEmpty {
            menu.addItem(.separator())
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
            menu.addItem(projectItem)
        }
        item.menu = menu
        let scope = presentation.isViewingArchive ? "Archived" : "Recent"
        item.toolTip = presentation.historyProjectFilter.map {
            "\(scope) history in \($0)"
        } ?? "\(scope) history in all projects"
    }

    @objc func selectHistoryProject(_ sender: NSMenuItem) {
        presentation.historyProjectFilter = sender.representedObject as? String
        updateHistoryFilterMenu()
    }

    @objc func selectHistoryArchive(_ sender: NSMenuItem) {
        presentation.isViewingArchive = (sender.representedObject as? Bool) == true
        updateHistoryFilterMenu()
    }

    @objc func historySearchChanged(_ sender: NSSearchField) {
        presentation.historySearchQuery = sender.stringValue
    }

}
