import AppKit

extension NowSpeakingPanelController {
    func showIdleIfNeeded() {
        guard presentation.lingeringItem?.isPendingQuestion != true else { return }
        presentation.lingeringItem = nil
        lastCurrentItem = nil
        activeItemID = nil
        guard !panel.isVisible else { return }
        showPlayer(activating: false)
    }

    func showPlayer(activating: Bool = true) {
        setPlayerVisible(true)
        if activating {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func presentationDidChange() {
        updateQuestionInputAvailability()
        updateHistoryNavigation()
        updateHistorySearchToolbar()
        updateBulkArchiveToolbarItem()
        synchronizeVisibleAskQueueHold()
        if let preview = presentation.pendingPreviewItem {
            sessionOpener.refresh(rawIdentifier: preview.iTermSessionID)
        }
        let isHovered = presentation.isHovered
        guard isHovered != observedHover else { return }
        observedHover = isHovered
        if isHovered {
            hoverAdvanceTask?.cancel()
            hoverAdvanceTask = nil
        } else {
            scheduleWindowedHoverContinuation()
        }
    }

    func scheduleWindowedHoverContinuation() {
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Layout.hoverExitContinuationSeconds))
            guard !Task.isCancelled, let self else { return }
            hoverAdvanceTask = nil
            guard presentation.lingeringItem?.isPendingQuestion != true else {
                synchronizeVisibleAskQueueHold()
                return
            }
            presentation.lingeringItem = nil
            presentation.lingeringTime = 0
            presentation.lingeringDuration = 0
            lastCurrentItem = nil
            synchronizeVisibleAskQueueHold()
            if playbackController.currentItem == nil {
                activeItemID = nil
                sessionOpener.clear()
                showIdleIfNeeded()
            }
        }
    }

    func hide() {
        guard activeItemID != nil || panel.isVisible else { return }
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = nil
        playbackController.setVisibleAskQueueHold(nil)
        activeItemID = nil
        lastCurrentItem = nil
        lastDuration = 0
        sessionOpener.clear()
        panel.orderOut(nil)
        observedHover = false
        presentation.clearHover()
        presentation.lingeringItem = nil
        presentation.lingeringTime = 0
        presentation.lingeringDuration = 0
        updateActivationPolicy()
    }

    func synchronizeVisibleAskQueueHold() {
        let itemID = VisibleAskQueueHoldPolicy.heldItemID(
            isPlayerVisible: isPlayerVisible,
            isWindowVisible: panel.isVisible && !panel.isMiniaturized,
            currentItem: playbackController.currentItem,
            pendingPreviewItem: presentation.pendingPreviewItem,
            lingeringItem: presentation.lingeringItem,
            hiddenItemID: presentation.hiddenItemID
        )
        playbackController.setVisibleAskQueueHold(itemID)
    }

    func updateActivationPolicy() {
        NSApp.setActivationPolicy(.regular)
    }

    func beginLingerIfNeeded() {
        guard panel.isVisible, let lastCurrentItem else {
            hide()
            return
        }
        guard presentation.lingeringItem == nil else { return }

        let duration = max(lastDuration, lastCurrentItem.duration ?? 0)
        presentation.lingeringItem = lastCurrentItem
        presentation.lingeringDuration = duration
        presentation.lingeringTime = duration
    }

    func schedulePositionSave() {
        scheduleGeometrySave()
    }

    func scheduleGeometrySave() {
        geometrySaveTask?.cancel()
        geometrySaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            geometrySaveTask = nil
            preferencesStore.setOrigin(panel.frame.origin)
            preferencesStore.setExpandedSize(panel.frame.size)
        }
    }
}
