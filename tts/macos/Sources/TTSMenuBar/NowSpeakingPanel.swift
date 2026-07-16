import AppKit
import Combine
import SwiftUI

@MainActor
final class NowSpeakingPanelController: NSObject, ObservableObject {
    enum Layout {
        static let expandedSize = NSSize(width: 540, height: 470)
        static let hoverExitContinuationSeconds: TimeInterval = 2
    }

    let playbackController: PlaybackController
    let preferencesStore: PlayerWindowPreferencesStore
    let playerPreferencesStore: PlayerPreferencesStore
    let presentation: NowSpeakingPresentation
    let sessionOpener: AgentSessionOpener
    var panel: NSWindow
    @Published private(set) var isPlayerVisible: Bool
    var playbackObservation: AnyCancellable?
    var presentationObservation: AnyCancellable?
    var screenObservation: AnyCancellable?
    var moveObservation: AnyCancellable?
    var resizeObservation: AnyCancellable?
    var closeObservation: AnyCancellable?
    var visibilityObservation: AnyCancellable?
    var geometrySaveTask: Task<Void, Never>?
    var hoverAdvanceTask: Task<Void, Never>?
    var activeItemID: String?
    var lastCurrentItem: TTSItem?
    var lastDuration: TimeInterval = 0
    var observedHover = false
    var historyFilterToolbarItem: NSMenuToolbarItem?
    var historyBackToolbarItem: NSToolbarItem?

    init(
        controller: PlaybackController,
        preferencesStore: PlayerWindowPreferencesStore,
        playerPreferencesStore: PlayerPreferencesStore,
        sessionOpener: AgentSessionOpener = AgentSessionOpener()
    ) {
        playbackController = controller
        self.preferencesStore = preferencesStore
        self.playerPreferencesStore = playerPreferencesStore
        self.sessionOpener = sessionOpener
        presentation = NowSpeakingPresentation()
        isPlayerVisible = true
        panel = Self.makeWindow(initialSize: Layout.expandedSize)
        super.init()

        configurePanel()
        attachContentView()

        playbackObservation = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        presentationObservation = presentation.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.presentationDidChange()
            }
        }
        screenObservation = NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        ).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleGeometrySave()
            }
        }
        setUpPanelObservations()
    }

    static func makeWindow(initialSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TTS Player"
        return window
    }

    func attachContentView() {
        let content = NowSpeakingHUDView(
            controller: playbackController,
            presentation: presentation,
            sessionOpener: sessionOpener,
            playerPreferencesStore: playerPreferencesStore
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    func setUpPanelObservations() {
        moveObservation = NotificationCenter.default.publisher(
            for: NSWindow.didMoveNotification,
            object: panel
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.schedulePositionSave()
            }
        }
        resizeObservation = NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification,
            object: panel
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.scheduleGeometrySave()
            }
        }
        closeObservation = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification,
            object: panel
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.setPlayerVisible(false)
            }
        }
        visibilityObservation = Publishers.Merge(
            NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification, object: panel),
            NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification, object: panel)
        ).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        defer {
            updateHistoryNavigation()
            synchronizeVisibleAskQueueHold()
        }
        updateHistoryFilterMenu()
        synchronizePendingPreview()
        synchronizeLingeringQuestion()
        updateQuestionInputAvailability()
        guard isPlayerVisible else {
            sessionOpener.clear()
            if panel.isVisible || activeItemID != nil {
                hide()
            }
            return
        }
        guard let item = playbackController.currentItem else {
            if let pendingQuestion = PendingQuestionRetention.retainedItem(
                currentItem: nil,
                lingeringItem: presentation.lingeringItem,
                lastCurrentItem: lastCurrentItem
            ) {
                lastCurrentItem = pendingQuestion
                sessionOpener.refresh(rawIdentifier: pendingQuestion.iTermSessionID)
                beginLingerIfNeeded()
                if !panel.isVisible { showPlayer(activating: false) }
            } else if PlayerHoverContinuation.shouldRetainCurrentContent(
                isHovered: presentation.isHovered,
                isGracePeriodActive: hoverAdvanceTask != nil,
                hasCurrentContent: lastCurrentItem != nil
            ) {
                sessionOpener.refresh(rawIdentifier: lastCurrentItem?.iTermSessionID)
                beginLingerIfNeeded()
                if !panel.isVisible { showPlayer(activating: false) }
            } else if presentation.pendingPreviewItem != nil {
                if !panel.isVisible { showPlayer(activating: false) }
            } else {
                presentation.lingeringItem = nil
                presentation.lingeringTime = 0
                presentation.lingeringDuration = 0
                lastCurrentItem = nil
                activeItemID = nil
                sessionOpener.clear()
                showIdleIfNeeded()
            }
            return
        }

        presentation.revealAutomatically(itemID: item.id)

        if presentation.lingeringItem != nil {
            presentation.lingeringItem = nil
        }
        presentation.clearPendingPreview()
        if item.isAttachmentPlayback,
           presentation.selectedAttachmentID == item.attachmentID
        {
            presentation.selectAttachment(nil)
        }
        lastCurrentItem = item
        lastDuration = max(playbackController.duration, item.duration ?? 0)
        sessionOpener.refresh(rawIdentifier: item.iTermSessionID)

        if activeItemID != item.id {
            activeItemID = item.id
            showPlayer(activating: false)
        } else if !panel.isVisible {
            showPlayer(activating: false)
        }
    }

    func synchronizePendingPreview() {
        guard let preview = presentation.pendingPreviewItem else { return }
        let latest = playbackController.items.first { $0.id == preview.id }
        guard let latest else {
            presentation.clearPendingPreview()
            return
        }
        if latest.status == .failed || latest.status == .played, !latest.isPendingQuestion {
            presentation.clearPendingPreview()
        } else {
            presentation.updatePendingPreview(with: latest)
        }
    }

    func synchronizeLingeringQuestion() {
        guard let lingering = presentation.lingeringItem, lingering.isQuestion else { return }
        guard let latest = playbackController.items.first(where: { $0.id == lingering.id }) else {
            return
        }
        if latest.isPendingQuestion {
            presentation.lingeringItem = latest
            lastCurrentItem = latest
        } else {
            presentation.lingeringItem = nil
            lastCurrentItem = nil
        }
    }

    func updateQuestionInputAvailability() {
        // A normal document window accepts focus whenever the user selects it.
    }

    func shutdown() {
        playbackObservation?.cancel()
        presentationObservation?.cancel()
        screenObservation?.cancel()
        moveObservation?.cancel()
        resizeObservation?.cancel()
        visibilityObservation?.cancel()
        geometrySaveTask?.cancel()
        hoverAdvanceTask?.cancel()
        playbackController.setVisibleAskQueueHold(nil)
        if panel.isVisible {
            preferencesStore.setOrigin(panel.frame.origin)
            preferencesStore.setExpandedSize(panel.frame.size)
        }
        panel.orderOut(nil)
    }

    func togglePlayerVisibility() {
        setPlayerVisible(!isPlayerVisible)
    }

    func setPlayerVisible(_ visible: Bool) {
        guard visible != isPlayerVisible else { return }
        isPlayerVisible = visible
        preferencesStore.setPlayerVisible(visible)
        if visible {
            refresh()
        } else {
            hide()
        }
    }

    func dismissPlayerContent() {
        let hiddenItemID = playbackController.currentItem?.id
            ?? presentation.pendingPreviewItem?.id
            ?? presentation.lingeringItem?.id
        presentation.showHistory(hiding: hiddenItemID)
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = nil
        playbackController.clearVisibleAskQueueHold(for: hiddenItemID)
        presentation.clearPendingPreview()
        presentation.lingeringItem = nil
        presentation.lingeringTime = 0
        presentation.lingeringDuration = 0
        lastCurrentItem = playbackController.currentItem
        activeItemID = playbackController.currentItem?.id
        showIdleIfNeeded()
        updateHistoryNavigation()
        synchronizeVisibleAskQueueHold()
    }

    func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.hasShadow = true
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = Layout.expandedSize
        panel.setAccessibilityLabel("TTS Player")
        configureHistoryToolbar()
    }

}
