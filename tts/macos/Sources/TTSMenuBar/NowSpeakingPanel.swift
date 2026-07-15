import AppKit
import Combine
import SwiftUI

@MainActor
final class NowSpeakingPanelController: NSObject, ObservableObject {
    private enum Layout {
        static let compactSize = NSSize(width: 400, height: 120)
        static let expandedSize = NSSize(width: 540, height: 470)
        static let screenInset: CGFloat = 20
        static let lingerSeconds: TimeInterval = 8
        static let hoverExitContinuationSeconds: TimeInterval = 2
        static let fadeSeconds: TimeInterval = 0.34
    }

    private static let historyToolbarIdentifier = NSToolbar.Identifier("TTSHistoryToolbar")
    private static let historyBackItemIdentifier = NSToolbarItem.Identifier("TTSHistoryBack")
    private static let historyFilterItemIdentifier = NSToolbarItem.Identifier("TTSHistoryProjectFilter")
    private static let historySearchItemIdentifier = NSToolbarItem.Identifier("TTSHistorySearch")

    private let playbackController: PlaybackController
    private let preferencesStore: HUDPreferencesStore
    private let playerPreferencesStore: PlayerPreferencesStore
    private let presentation: NowSpeakingPresentation
    private let sessionOpener: AgentSessionOpener
    private var panel: NSWindow
    private var windowedMode: Bool
    @Published private(set) var isPlayerVisible: Bool
    @Published private(set) var isWindowedMode: Bool
    private var playbackObservation: AnyCancellable?
    private var playerPreferencesObservation: AnyCancellable?
    private var presentationObservation: AnyCancellable?
    private var screenObservation: AnyCancellable?
    private var moveObservation: AnyCancellable?
    private var resizeObservation: AnyCancellable?
    private var liveResizeEndObservation: AnyCancellable?
    private var closeObservation: AnyCancellable?
    private var lingerTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var geometrySaveTask: Task<Void, Never>?
    private var hoverAdvanceTask: Task<Void, Never>?
    private var activeItemID: String?
    private var lastCurrentItem: TTSItem?
    private var lastDuration: TimeInterval = 0
    private var lingerCountdown = LingerCountdown(duration: Layout.lingerSeconds)
    private var observedHover = false
    private var observedMiniPlayer: Bool
    private var isFading = false
    private var historyFilterToolbarItem: NSMenuToolbarItem?
    private var historyBackToolbarItem: NSToolbarItem?
    private var didBringToFrontForActiveContent = false
    private var windowedOpacityTask: Task<Void, Never>?

    /// Whether the controller drives the floating-HUD chrome. When `true` the
    /// controller owns the panel's frame and lifetime: custom edge-resize,
    /// screen-inset clamping, auto-positioning on screen changes, alpha fades,
    /// the mini/expanded toggle, and the linger auto-hide. When `false`
    /// (windowed mode) all of that is delegated to a standard OS window that the
    /// user moves, resizes, and closes, so none of those routines may run.
    ///
    /// Gate every HUD-only frame/visibility routine on this so windowed mode can
    /// never be repositioned, resized, faded, or auto-hidden underneath the
    /// user. Use `windowedMode` directly only for windowed-only features (idle
    /// history, Dock activation, in-place `orderFront`).
    private var usesFloatingHUD: Bool { !windowedMode }

    private var needsExpandedLayout: Bool {
        playbackController.currentItem?.isQuestion == true
            || presentation.pendingPreviewItem?.isQuestion == true
            || presentation.lingeringItem?.isQuestion == true
            || presentation.isExpanded
    }

    init(
        controller: PlaybackController,
        preferencesStore: HUDPreferencesStore,
        playerPreferencesStore: PlayerPreferencesStore,
        sessionOpener: AgentSessionOpener = AgentSessionOpener()
    ) {
        playbackController = controller
        self.preferencesStore = preferencesStore
        self.playerPreferencesStore = playerPreferencesStore
        self.sessionOpener = sessionOpener
        let windowed = preferencesStore.preferences.isWindowedModeEnabled
        windowedMode = windowed
        isWindowedMode = windowed
        presentation = NowSpeakingPresentation(
            isMiniPlayer: windowed ? false : preferencesStore.preferences.isMiniPlayer
        )
        isPlayerVisible = preferencesStore.preferences.isPlayerVisible
        observedMiniPlayer = windowed ? false : preferencesStore.preferences.isMiniPlayer
        panel = Self.makeWindow(windowed: windowed, initialSize: Layout.expandedSize)
        super.init()

        configurePanel()
        attachContentView()

        playbackObservation = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        playerPreferencesObservation = playerPreferencesStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateWindowLevel()
                self?.updateWindowedOpacity()
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
                guard let self, self.usesFloatingHUD else { return }
                let size = self.needsExpandedLayout
                    ? self.preferredExpandedSize
                    : Layout.compactSize
                self.configureResizeLimits(expanded: self.needsExpandedLayout)
                self.positionPanel(size: size)
            }
        }
        setUpPanelObservations()
    }

    private static func makeWindow(windowed: Bool, initialSize: NSSize) -> NSWindow {
        if windowed {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "TTS Player"
            return window
        }
        return PassiveHUDPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func attachContentView() {
        let content = NowSpeakingHUDView(
            controller: playbackController,
            presentation: presentation,
            sessionOpener: sessionOpener,
            playerPreferencesStore: playerPreferencesStore,
            isWindowedMode: windowedMode,
            onToggleMiniPlayer: { [weak self] in self?.toggleMiniPlayer() }
        )
        // The floating HUD is always a dark glass overlay by design; a normal
        // window should instead follow the system's light/dark appearance.
        let rootView: AnyView = windowedMode
            ? AnyView(content)
            : AnyView(content.environment(\.colorScheme, .dark))
        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    private func setUpPanelObservations() {
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
        liveResizeEndObservation = NotificationCenter.default.publisher(
            for: NSWindow.didEndLiveResizeNotification,
            object: panel
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.clampCurrentFrameToVisibleScreen()
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
    }

    func toggleWindowedMode() {
        setWindowedMode(!windowedMode)
    }

    func setWindowedMode(_ windowed: Bool) {
        guard windowed != windowedMode else { return }
        let wasVisible = panel.isVisible
        let retainedPendingQuestion = PendingQuestionRetention.retainedItem(
            currentItem: playbackController.currentItem,
            lingeringItem: presentation.lingeringItem,
            lastCurrentItem: lastCurrentItem
        )

        cancelLingerDismissal(resetCountdown: true, restoreOpacity: false)
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = nil
        playbackController.setAutomaticQueueAdvanceDeferred(false)
        presentation.lingeringItem = nil
        presentation.lingeringTime = 0
        presentation.lingeringDuration = 0
        presentation.setMiniPlayer(windowed ? false : preferencesStore.preferences.isMiniPlayer)
        observedMiniPlayer = presentation.isMiniPlayer

        moveObservation?.cancel()
        resizeObservation?.cancel()
        liveResizeEndObservation?.cancel()
        closeObservation?.cancel()
        panel.contentView = nil
        panel.orderOut(nil)

        windowedMode = windowed
        isWindowedMode = windowed
        preferencesStore.setWindowedMode(windowed)

        panel = Self.makeWindow(windowed: windowed, initialSize: preferredExpandedSize)
        configurePanel()
        attachContentView()
        setUpPanelObservations()

        activeItemID = nil
        didBringToFrontForActiveContent = false
        lastCurrentItem = retainedPendingQuestion
        if playbackController.currentItem == nil {
            presentation.lingeringItem = retainedPendingQuestion
        }
        if wasVisible {
            refresh()
        } else {
            updateWindowLevel()
            updateActivationPolicy()
        }
    }

    func refresh() {
        defer { updateHistoryBackButton() }
        updateHistoryFilterMenu()
        synchronizePendingPreview()
        synchronizeLingeringQuestion()
        updateQuestionInputAvailability()
        updateWindowLevel()
        updateWindowedOpacity()
        guard isPlayerVisible else {
            sessionOpener.clear()
            if panel.isVisible || activeItemID != nil {
                hide()
            }
            return
        }
        guard let item = playbackController.currentItem else {
            if windowedMode {
                if PlayerHoverContinuation.shouldRetainCurrentContent(
                    isHovered: presentation.isHovered,
                    isGracePeriodActive: hoverAdvanceTask != nil,
                    hasCurrentContent: lastCurrentItem != nil
                ) {
                    sessionOpener.refresh(rawIdentifier: lastCurrentItem?.iTermSessionID)
                    beginLingerIfNeeded()
                    if !panel.isVisible { showPlayer() }
                } else if presentation.pendingPreviewItem != nil {
                    if !panel.isVisible { showPlayer() }
                } else {
                    presentation.lingeringItem = nil
                    presentation.lingeringTime = 0
                    presentation.lingeringDuration = 0
                    lastCurrentItem = nil
                    activeItemID = nil
                    sessionOpener.clear()
                    showIdleIfNeeded()
                }
            } else if PendingQuestionRetention.shouldRetain(
                lastCurrentItem: lastCurrentItem,
                lingeringItem: presentation.lingeringItem
            ) {
                sessionOpener.refresh(rawIdentifier: lastCurrentItem?.iTermSessionID)
                beginLingerIfNeeded()
                if !panel.isVisible { showPlayer() }
            } else {
                sessionOpener.refresh(rawIdentifier: lastCurrentItem?.iTermSessionID)
                beginLingerIfNeeded()
            }
            return
        }

        presentation.revealAutomatically(itemID: item.id)

        if presentation.lingeringItem != nil || lingerTask != nil || isFading {
            cancelLingerDismissal(resetCountdown: true, restoreOpacity: true)
        }
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
            if windowedMode, panel.isVisible {
                // Bring the window to the front once when active playback begins,
                // unless the user asked for a strictly normal window that never
                // auto-raises. Always-on-top modes are handled by updateWindowLevel.
                if !didBringToFrontForActiveContent,
                   playerPreferencesStore.preferences.floatnessMode == .bringToFrontWhenPlaying
                {
                    panel.orderFront(nil)
                }
            } else {
                showPlayer()
            }
        } else if !panel.isVisible {
            showPlayer()
        }
        didBringToFrontForActiveContent = isShowingActiveContent
    }

    private func synchronizePendingPreview() {
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

    private func synchronizeLingeringQuestion() {
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

    private func updateQuestionInputAvailability() {
        guard let passivePanel = panel as? PassiveHUDPanel else { return }
        passivePanel.allowsQuestionEditing = playbackController.currentItem?.isPendingQuestion == true
            || presentation.pendingPreviewItem?.isPendingQuestion == true
            || presentation.lingeringItem?.isPendingQuestion == true
    }

    func shutdown() {
        playbackObservation?.cancel()
        playerPreferencesObservation?.cancel()
        presentationObservation?.cancel()
        screenObservation?.cancel()
        moveObservation?.cancel()
        resizeObservation?.cancel()
        liveResizeEndObservation?.cancel()
        lingerTask?.cancel()
        fadeTask?.cancel()
        geometrySaveTask?.cancel()
        hoverAdvanceTask?.cancel()
        playbackController.setAutomaticQueueAdvanceDeferred(false)
        if panel.isVisible {
            preferencesStore.setOrigin(panel.frame.origin)
            if presentation.isExpanded {
                preferencesStore.setExpandedSize(panel.frame.size)
            }
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

    private func dismissPlayerContent() {
        guard windowedMode else {
            setPlayerVisible(false)
            return
        }
        let hiddenItemID = playbackController.currentItem?.id
            ?? presentation.pendingPreviewItem?.id
            ?? presentation.lingeringItem?.id
        presentation.showHistory(hiding: hiddenItemID)
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = nil
        playbackController.setAutomaticQueueAdvanceDeferred(false)
        presentation.clearPendingPreview()
        presentation.lingeringItem = nil
        presentation.lingeringTime = 0
        presentation.lingeringDuration = 0
        lastCurrentItem = playbackController.currentItem
        activeItemID = playbackController.currentItem?.id
        showIdleIfNeeded()
        updateHistoryBackButton()
    }

    func toggleMiniPlayer() {
        let useMiniPlayer = !presentation.isMiniPlayer
        if useMiniPlayer, presentation.isExpanded {
            preferencesStore.setExpandedSize(panel.frame.size)
        }
        preferencesStore.setMiniPlayer(useMiniPlayer)
        presentation.setMiniPlayer(useMiniPlayer)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        if windowedMode {
            panel.isOpaque = true
            panel.hasShadow = true
            panel.level = .normal
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.minSize = Layout.expandedSize
            panel.setAccessibilityLabel("TTS Player")
            configureHistoryToolbar()
        } else {
            panel.level = .floating
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary,
            ]
            (panel as? NSPanel)?.isFloatingPanel = true
            // The HUD is presented without activation. It may become key only
            // after the user deliberately clicks the question composer.
            (panel as? NSPanel)?.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.isMovable = true
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.animationBehavior = .utilityWindow
            panel.setAccessibilityLabel("Now speaking")
            configureResizeLimits(expanded: true)
        }
    }

    private func updateWindowLevel() {
        guard windowedMode else { return }
        let mode = playerPreferencesStore.preferences.floatnessMode
        switch mode {
        case .normal:
            panel.level = .normal
        case .bringToFrontWhenPlaying:
            panel.level = .normal
        case .alwaysOnTop:
            panel.level = .floating
        case .alwaysOnTopWhilePlaying:
            panel.level = isShowingActiveContent ? .floating : .normal
        }
    }

    /// Whether the windowed player is currently showing active playback content
    /// (a current item, a lingering item, or a pending question) instead of the
    /// idle history queue. This is what "while playing" means for floatness: a
    /// pending question that is awaiting an answer keeps the player active even
    /// after audio finishes, so the window stays on top until the user answers,
    /// skips, or supersedes it.
    private var isShowingActiveContent: Bool {
        guard windowedMode else { return false }
        if playbackController.currentItem != nil { return true }
        if presentation.lingeringItem != nil { return true }
        if presentation.pendingPreviewItem != nil { return true }
        return false
    }

    /// Drives the windowed-player transparency. When the user is not hovering,
    /// the window fades to the saved opacity; on hover it animates back to fully
    /// opaque so the player is always readable while being used.
    private func updateWindowedOpacity() {
        guard windowedMode, panel.isVisible else { return }
        let target = effectiveWindowedOpacity
        guard abs(panel.alphaValue - target) > 0.001 else { return }
        windowedOpacityTask?.cancel()
        windowedOpacityTask = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = target
        }
    }

    private var effectiveWindowedOpacity: CGFloat {
        guard windowedMode else { return 1 }
        if presentation.isHovered { return 1 }
        return CGFloat(playerPreferencesStore.preferences.windowOpacity)
    }

    private func configureHistoryToolbar() {
        let toolbar = NSToolbar(identifier: Self.historyToolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        panel.toolbarStyle = .unified
        panel.toolbar = toolbar
    }

    private func updateHistoryBackButton() {
        guard windowedMode else { return }
        let itemID = playbackController.currentItem?.id
            ?? presentation.pendingPreviewItem?.id
            ?? presentation.lingeringItem?.id
        historyBackToolbarItem?.isEnabled = itemID != nil
            && presentation.hiddenItemID != itemID
    }

    @objc private func navigateBackToHistory() {
        dismissPlayerContent()
    }

    private func updateHistoryFilterMenu() {
        guard windowedMode, let item = historyFilterToolbarItem else { return }
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

    @objc private func selectHistoryProject(_ sender: NSMenuItem) {
        presentation.historyProjectFilter = sender.representedObject as? String
        updateHistoryFilterMenu()
    }

    @objc private func selectHistoryArchive(_ sender: NSMenuItem) {
        presentation.isViewingArchive = (sender.representedObject as? Bool) == true
        updateHistoryFilterMenu()
    }

    @objc private func historySearchChanged(_ sender: NSSearchField) {
        presentation.historySearchQuery = sender.stringValue
    }

    private func showIdleIfNeeded() {
        guard presentation.lingeringItem?.isPendingQuestion != true else { return }
        if presentation.lingeringItem != nil || lingerTask != nil || isFading {
            cancelLingerDismissal(resetCountdown: true, restoreOpacity: true)
        }
        presentation.lingeringItem = nil
        lastCurrentItem = nil
        activeItemID = nil
        didBringToFrontForActiveContent = false
        updateWindowLevel()
        updateWindowedOpacity()
        guard !panel.isVisible else { return }
        showPlayer()
    }

    private func showPlayer() {
        configureResizeLimits(expanded: needsExpandedLayout)
        positionPanel(size: needsExpandedLayout ? preferredExpandedSize : Layout.compactSize)
        if usesFloatingHUD {
            // Fade the floating panel in above every space.
            panel.alphaValue = 0
            NSApp.unhideWithoutActivation()
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            // Windowed mode: start at the effective opacity (saved transparency
            // unless hovered), then order front.
            panel.alphaValue = effectiveWindowedOpacity
            NSApp.unhideWithoutActivation()
            panel.orderFront(nil)
        }
        // panel.isVisible only flips true once ordered front, so this must run last.
        updateActivationPolicy()
    }

    private func updateLayout(animated: Bool) {
        // HUD-only: this drives the floating panel's frame and alpha as the
        // mini/expanded state changes. Windowed mode never resizes or repositions
        // itself programmatically, so it must not run through here.
        guard usesFloatingHUD else { return }
        if playbackController.currentItem == nil, presentation.lingeringItem == nil {
            hide()
            return
        }
        guard panel.isVisible else { return }
        let expanded = needsExpandedLayout
        configureResizeLimits(expanded: expanded)
        let size = expanded ? preferredExpandedSize : Layout.compactSize
        let frame = frameFor(size: size)
        let alpha: CGFloat = presentation.isExpanded ? 1 : 0.84
        guard HUDLayoutUpdate.isNeeded(
            currentFrame: panel.frame,
            targetFrame: frame,
            currentAlpha: panel.alphaValue,
            targetAlpha: alpha
        ) else { return }

        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if !panel.frame.equalTo(frame) {
                panel.animator().setFrame(frame, display: true)
            }
            if abs(panel.alphaValue - alpha) > 0.001 {
                panel.animator().alphaValue = alpha
            }
        }
    }

    private func presentationDidChange() {
        updateQuestionInputAvailability()
        updateHistoryBackButton()
        let miniPlayer = presentation.isMiniPlayer
        if miniPlayer != observedMiniPlayer {
            observedMiniPlayer = miniPlayer
            updateLayout(animated: true)
        }

        let isHovered = presentation.isHovered
        guard isHovered != observedHover else { return }
        observedHover = isHovered

        if windowedMode {
            // Hovering restores full opacity and temporarily holds the current
            // content instead of advancing the queue underneath the pointer.
            updateWindowedOpacity()
            if isHovered {
                hoverAdvanceTask?.cancel()
                hoverAdvanceTask = nil
                playbackController.setAutomaticQueueAdvanceDeferred(true)
            } else {
                scheduleWindowedHoverContinuation()
            }
            return
        }

        guard playbackController.currentItem == nil, presentation.lingeringItem != nil else { return }

        // Pending questions remain available until answered, skipped, or
        // superseded. Hovering must not start their ordinary speech timeout.
        guard presentation.lingeringItem?.isPendingQuestion != true else { return }

        if isHovered {
            lingerCountdown.pause(at: ProcessInfo.processInfo.systemUptime)
            lingerTask?.cancel()
            lingerTask = nil
            cancelFade(restoreOpacity: true)
        } else {
            scheduleLingerDismissal()
        }
    }

    private func scheduleWindowedHoverContinuation() {
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Layout.hoverExitContinuationSeconds))
            guard !Task.isCancelled, let self else { return }
            hoverAdvanceTask = nil
            presentation.lingeringItem = nil
            presentation.lingeringTime = 0
            presentation.lingeringDuration = 0
            lastCurrentItem = nil
            playbackController.setAutomaticQueueAdvanceDeferred(false)
            if playbackController.currentItem == nil {
                activeItemID = nil
                sessionOpener.clear()
                showIdleIfNeeded()
            }
        }
    }

    private func hide() {
        guard activeItemID != nil || panel.isVisible else { return }
        cancelLingerDismissal(resetCountdown: true, restoreOpacity: false)
        hoverAdvanceTask?.cancel()
        hoverAdvanceTask = nil
        playbackController.setAutomaticQueueAdvanceDeferred(false)
        activeItemID = nil
        lastCurrentItem = nil
        lastDuration = 0
        didBringToFrontForActiveContent = false
        sessionOpener.clear()
        panel.orderOut(nil)
        panel.alphaValue = 1
        observedHover = false
        presentation.clearHover()
        presentation.lingeringItem = nil
        presentation.lingeringTime = 0
        presentation.lingeringDuration = 0
        updateActivationPolicy()
    }

    /// Windowed mode should behave like a normal app (Dock icon, Cmd+Tab) only
    /// while its window is actually on screen; otherwise this stays a menu-bar-only accessory.
    private func updateActivationPolicy() {
        let shouldBeRegular = windowedMode && panel.isVisible
        let target: NSApplication.ActivationPolicy = shouldBeRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular {
            // Without an activation nudge, LaunchServices/Dock can take several
            // seconds (or never) to register the Dock tile after this policy change.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func beginLingerIfNeeded() {
        guard panel.isVisible, let lastCurrentItem else {
            hide()
            return
        }
        guard presentation.lingeringItem == nil else { return }

        let duration = max(lastDuration, lastCurrentItem.duration ?? 0)
        presentation.lingeringItem = lastCurrentItem
        presentation.lingeringDuration = duration
        presentation.lingeringTime = duration
        if lastCurrentItem.isPendingQuestion {
            cancelLingerDismissal(resetCountdown: true, restoreOpacity: true)
            return
        }
        lingerCountdown.start(at: ProcessInfo.processInfo.systemUptime)
        if presentation.isHovered {
            lingerCountdown.pause(at: ProcessInfo.processInfo.systemUptime)
        } else {
            scheduleLingerDismissal()
        }
    }

    private func scheduleLingerDismissal() {
        guard presentation.lingeringItem?.isPendingQuestion != true else { return }
        lingerTask?.cancel()
        cancelFade(restoreOpacity: true)
        let now = ProcessInfo.processInfo.systemUptime
        lingerCountdown.resume(at: now)
        let remaining = lingerCountdown.timeRemaining(at: now)

        guard remaining > 0 else {
            beginFadeOut()
            return
        }
        lingerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard playbackController.currentItem == nil else { return }
            lingerCountdown.pause(at: ProcessInfo.processInfo.systemUptime)
            beginFadeOut()
        }
    }

    private func beginFadeOut() {
        guard !presentation.isHovered,
              playbackController.currentItem == nil,
              presentation.lingeringItem != nil,
              presentation.lingeringItem?.isPendingQuestion != true else { return }
        lingerTask?.cancel()
        lingerTask = nil
        fadeTask?.cancel()
        isFading = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Layout.fadeSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, isFading else { return }
            guard playbackController.currentItem == nil,
                  !presentation.isHovered else { return }
            hide()
        }
    }

    private func cancelLingerDismissal(resetCountdown: Bool, restoreOpacity: Bool) {
        lingerTask?.cancel()
        lingerTask = nil
        cancelFade(restoreOpacity: restoreOpacity)
        if resetCountdown {
            lingerCountdown.cancel()
        }
    }

    private func cancelFade(restoreOpacity: Bool) {
        fadeTask?.cancel()
        fadeTask = nil
        isFading = false
        guard restoreOpacity, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    private func positionPanel(size: NSSize) {
        panel.setFrame(frameFor(size: size), display: true)
    }

    private func frameFor(size: NSSize) -> NSRect {
        HUDPlacement.frame(
            size: size,
            preferredOrigin: preferencesStore.preferences.origin,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            inset: Layout.screenInset
        )
    }

    private var preferredExpandedSize: NSSize {
        HUDPlacement.preferredExpandedSize(
            saved: preferencesStore.preferences.expandedSize,
            minimum: Layout.expandedSize
        )
    }

    private func configureResizeLimits(expanded: Bool) {
        // HUD-only: min/max sizes clamp the custom edge-resize to the screen.
        // Windowed mode uses the native resize handle with its own limits.
        guard usesFloatingHUD else { return }
        let maximumSize = HUDPlacement.frame(
            size: CGSize(width: 100_000, height: 100_000),
            preferredOrigin: preferencesStore.preferences.origin,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            inset: Layout.screenInset
        ).size
        if expanded {
            panel.minSize = NSSize(
                width: min(Layout.expandedSize.width, maximumSize.width),
                height: min(Layout.expandedSize.height, maximumSize.height)
            )
            panel.maxSize = maximumSize
        } else {
            let compactSize = frameFor(size: Layout.compactSize).size
            panel.minSize = compactSize
            panel.maxSize = compactSize
        }
    }

    private func clampCurrentFrameToVisibleScreen() {
        // HUD-only: the floating panel is kept inside the screen inset after a
        // custom edge-resize. A windowed player is resized natively by the OS and
        // must keep exactly the frame the user dragged, so never clamp it.
        guard usesFloatingHUD else { return }
        let frame = HUDPlacement.frame(
            size: panel.frame.size,
            preferredOrigin: panel.frame.origin,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            inset: Layout.screenInset
        )
        panel.setFrame(frame, display: true)
        scheduleGeometrySave()
    }

    private func schedulePositionSave() {
        scheduleGeometrySave()
    }

    private func scheduleGeometrySave() {
        geometrySaveTask?.cancel()
        geometrySaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            geometrySaveTask = nil
            preferencesStore.setOrigin(panel.frame.origin)
            if presentation.isExpanded {
                preferencesStore.setExpandedSize(panel.frame.size)
            }
        }
    }
}

extension NowSpeakingPanelController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.historyBackItemIdentifier,
            .flexibleSpace,
            Self.historySearchItemIdentifier,
            Self.historyFilterItemIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.historyBackItemIdentifier,
            .flexibleSpace,
            Self.historySearchItemIdentifier,
            Self.historyFilterItemIdentifier,
        ]
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.historyBackItemIdentifier:
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
            updateHistoryBackButton()
            return item
        case Self.historySearchItemIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search History"
            item.searchField.placeholderString = "Search speech"
            item.searchField.target = self
            item.searchField.action = #selector(historySearchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.stringValue = presentation.historySearchQuery
            item.searchField.setAccessibilityLabel("Search speech history")
            return item
        case Self.historyFilterItemIdentifier:
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
        default:
            return nil
        }
    }
}

final class PassiveHUDPanel: NSPanel {
    // Ordinary playback can never take focus. A pending question temporarily
    // enables key status so a deliberate composer click can accept input;
    // ordering the non-activating panel still does not make it key.
    var allowsQuestionEditing = false
    override var canBecomeKey: Bool { allowsQuestionEditing }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

private struct PlayerResizeRegions: NSViewRepresentable {
    func makeNSView(context _: Context) -> PlayerResizeRegionsView {
        PlayerResizeRegionsView()
    }

    func updateNSView(_: PlayerResizeRegionsView, context _: Context) {}
}

private final class PlayerResizeRegionsView: NSView {
    private static let hitWidth: CGFloat = 12
    private static let cornerWidth: CGFloat = 20
    private static let minimumSize = CGSize(width: 540, height: 470)
    private var initialFrame: NSRect?
    private var initialPointer: NSPoint?
    private var activeEdges: HUDResizeEdges = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: point).isEmpty ? nil : self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        initialFrame = window?.frame
        initialPointer = NSEvent.mouseLocation
    }

    override func mouseDragged(with _: NSEvent) {
        guard !activeEdges.isEmpty,
              let window,
              let initialFrame,
              let initialPointer else { return }
        let pointer = NSEvent.mouseLocation
        let delta = CGPoint(
            x: pointer.x - initialPointer.x,
            y: pointer.y - initialPointer.y
        )
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            .insetBy(dx: 20, dy: 20)
            ?? initialFrame
        let frame = HUDResize.frame(
            initialFrame: initialFrame,
            pointerDelta: delta,
            edges: activeEdges,
            visibleFrame: visibleFrame,
            minimumSize: Self.minimumSize
        )
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with _: NSEvent) {
        initialFrame = nil
        initialPointer = nil
        activeEdges = []
    }

    override func resetCursorRects() {
        let edge = Self.hitWidth
        let corner = Self.cornerWidth
        addCursorRect(NSRect(x: 0, y: corner, width: edge, height: max(0, bounds.height - 2 * corner)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edge, y: corner, width: edge, height: max(0, bounds.height - 2 * corner)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: corner, y: 0, width: max(0, bounds.width - 2 * corner), height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: corner, y: bounds.height - edge, width: max(0, bounds.width - 2 * corner), height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: corner, height: corner), cursor: Self.northeastSouthwestCursor)
        addCursorRect(NSRect(x: bounds.width - corner, y: bounds.height - corner, width: corner, height: corner), cursor: Self.northeastSouthwestCursor)
        addCursorRect(NSRect(x: 0, y: bounds.height - corner, width: corner, height: corner), cursor: Self.northwestSoutheastCursor)
        addCursorRect(NSRect(x: bounds.width - corner, y: 0, width: corner, height: corner), cursor: Self.northwestSoutheastCursor)
    }

    private func edges(at point: NSPoint) -> HUDResizeEdges {
        guard bounds.contains(point) else { return [] }
        var result: HUDResizeEdges = []
        let nearVerticalCorner = point.y <= Self.cornerWidth
            || point.y >= bounds.height - Self.cornerWidth
        let nearHorizontalCorner = point.x <= Self.cornerWidth
            || point.x >= bounds.width - Self.cornerWidth
        let horizontalThreshold = nearVerticalCorner ? Self.cornerWidth : Self.hitWidth
        let verticalThreshold = nearHorizontalCorner ? Self.cornerWidth : Self.hitWidth
        if point.x <= horizontalThreshold { result.insert(.left) }
        if point.x >= bounds.width - horizontalThreshold { result.insert(.right) }
        if point.y <= verticalThreshold { result.insert(.bottom) }
        if point.y >= bounds.height - verticalThreshold { result.insert(.top) }
        return result
    }

    private static let northwestSoutheastCursor = diagonalCursor(
        symbol: "arrow.up.left.and.arrow.down.right"
    )
    private static let northeastSouthwestCursor = diagonalCursor(
        symbol: "arrow.up.right.and.arrow.down.left"
    )

    private static func diagonalCursor(symbol: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return .crosshair
        }
        image.size = NSSize(width: 18, height: 18)
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }
}

@MainActor
private final class NowSpeakingPresentation: ObservableObject {
    @Published private(set) var isMiniPlayer: Bool
    @Published private(set) var isHovered = false
    @Published var lingeringItem: TTSItem?
    @Published var lingeringTime: TimeInterval = 0
    @Published var lingeringDuration: TimeInterval = 0
    @Published var selectedAttachmentID: String?
    @Published private(set) var selectedAttachmentText: String?
    @Published private(set) var selectedAttachmentImage: NSImage?
    @Published var historyProjectFilter: String?
    @Published var historySearchQuery = ""
    @Published var isViewingArchive = false
    @Published private(set) var pendingPreviewItem: TTSItem?
    @Published private(set) var hiddenItemID: String?
    private var hoverExitTask: Task<Void, Never>?

    init(isMiniPlayer: Bool) {
        self.isMiniPlayer = isMiniPlayer
    }

    var isExpanded: Bool {
        !isMiniPlayer
    }

    func setMiniPlayer(_ miniPlayer: Bool) {
        isMiniPlayer = miniPlayer
    }

    func updateHover(_ hovering: Bool) {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        if hovering {
            isHovered = true
            return
        }

        hoverExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            hoverExitTask = nil
            isHovered = false
        }
    }

    func clearHover() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        isHovered = false
    }

    func selectAttachment(
        _ attachmentID: String?,
        text: String? = nil,
        image: NSImage? = nil
    ) {
        selectedAttachmentID = attachmentID
        selectedAttachmentText = attachmentID == nil ? nil : text
        selectedAttachmentImage = attachmentID == nil ? nil : image
    }

    func previewPendingItem(_ item: TTSItem) {
        hiddenItemID = nil
        pendingPreviewItem = item
        selectAttachment(nil)
    }

    func revealForDirectSelection(itemID _: String) {
        hiddenItemID = nil
    }

    func revealAutomatically(itemID: String) {
        hiddenItemID = PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: itemID,
            currentlyHidden: hiddenItemID
        )
    }

    func showHistory(hiding itemID: String?) {
        hiddenItemID = itemID
        selectAttachment(nil)
    }

    func updatePendingPreview(with item: TTSItem?) {
        guard let preview = pendingPreviewItem else { return }
        guard let item, item.id == preview.id else {
            pendingPreviewItem = nil
            return
        }
        pendingPreviewItem = item
    }

    func clearPendingPreview() {
        pendingPreviewItem = nil
    }
}

enum PendingQuestionRetention {
    static func retainedItem(
        currentItem: TTSItem?,
        lingeringItem: TTSItem?,
        lastCurrentItem: TTSItem?
    ) -> TTSItem? {
        [currentItem, lingeringItem, lastCurrentItem]
            .compactMap { $0 }
            .first(where: \.isPendingQuestion)
    }

    static func shouldRetain(lastCurrentItem: TTSItem?, lingeringItem: TTSItem?) -> Bool {
        retainedItem(
            currentItem: nil,
            lingeringItem: lingeringItem,
            lastCurrentItem: lastCurrentItem
        ) != nil
    }
}

enum PlayerNavigationPolicy {
    static func shouldDisplay(itemID: String?, hiddenItemID: String?) -> Bool {
        itemID != nil && itemID != hiddenItemID
    }

    static func hiddenItemID(
        afterAutomaticallySelecting itemID: String,
        currentlyHidden hiddenItemID: String?
    ) -> String? {
        hiddenItemID == itemID ? hiddenItemID : nil
    }
}

enum PlayerHoverContinuation {
    static func shouldRetainCurrentContent(
        isHovered: Bool,
        isGracePeriodActive: Bool,
        hasCurrentContent: Bool
    ) -> Bool {
        hasCurrentContent && (isHovered || isGracePeriodActive)
    }
}

enum QuestionAudioReview {
    static func canReplay(
        _ item: TTSItem,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> Bool {
        item.isQuestion
            && item.status != .generating
            && fileExists(item.outputFile)
    }
}

struct QuestionSubmission: Equatable {
    let questionID: String
    let answer: String?
    let suggestionIDs: [String]
    let selectedSuggestions: [TTSQuestionDraftSuggestion]
    let attachmentURLs: [String]

    var suggestionID: String? { suggestionIDs.count == 1 ? suggestionIDs.first : nil }
    var isSkipped: Bool { answer == nil && attachmentURLs.isEmpty }
}

struct QuestionChoiceConfiguration: Equatable {
    let id: String
    let type: TTSQuestionType

    init(id: String, type: TTSQuestionType = .singleChoice) {
        self.id = id
        self.type = type
    }
}

struct SuggestionDraftState: Equatable {
    var title: String
    var description: String?
    var isEdited = false
    var attachmentURLs: [URL] = []

    var answer: String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct QuestionDraftState: Equatable {
    var freeformText = ""
    var selectedSuggestionIDs: [String] = []
    var suggestions: [String: SuggestionDraftState] = [:]
    var attachmentURLs: [URL] = []

    var selectedSuggestionID: String? { selectedSuggestionIDs.first }

    func suggestion(_ id: String) -> SuggestionDraftState? { suggestions[id] }
}

struct QuestionComposerModel: Equatable {
    private(set) var selectedQuestionID: String?
    private(set) var drafts: [String: QuestionDraftState] = [:]
    private(set) var questionTypes: [String: TTSQuestionType] = [:]

    mutating func prepare(questionIDs: [String]) {
        prepare(questions: questionIDs.map { QuestionChoiceConfiguration(id: $0) })
    }

    mutating func prepare(questions: [QuestionChoiceConfiguration]) {
        let available = Set(questions.map(\.id))
        drafts = drafts.filter { available.contains($0.key) }
        questionTypes = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.type) })
        for question in questions where drafts[question.id] == nil {
            drafts[question.id] = QuestionDraftState()
        }
        if selectedQuestionID.map({ available.contains($0) }) != true {
            selectedQuestionID = questions.first?.id
        }
    }

    func draft(for questionID: String) -> QuestionDraftState {
        drafts[questionID] ?? QuestionDraftState()
    }

    mutating func selectQuestion(_ questionID: String) {
        selectedQuestionID = questionID
        if drafts[questionID] == nil {
            drafts[questionID] = QuestionDraftState()
        }
    }

    mutating func updateDraft(_ value: String, for questionID: String) {
        ensureDraft(for: questionID)
        drafts[questionID]?.freeformText = value
        guard questionType(for: questionID) == .singleChoice,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts[questionID]?.selectedSuggestionIDs = []
    }

    mutating func selectSuggestion(
        id: String,
        title: String,
        description: String? = nil,
        for questionID: String
    ) {
        ensureDraft(for: questionID)
        if drafts[questionID]?.suggestions[id] == nil {
            drafts[questionID]?.suggestions[id] = SuggestionDraftState(
                title: title,
                description: description
            )
        } else if drafts[questionID]?.suggestions[id]?.isEdited != true {
            drafts[questionID]?.suggestions[id]?.title = title
            drafts[questionID]?.suggestions[id]?.description = description
        }
        if questionType(for: questionID) == .multipleChoice {
            if let index = drafts[questionID]?.selectedSuggestionIDs.firstIndex(of: id) {
                drafts[questionID]?.selectedSuggestionIDs.remove(at: index)
            } else {
                drafts[questionID]?.selectedSuggestionIDs.append(id)
            }
        } else {
            drafts[questionID]?.selectedSuggestionIDs = [id]
        }
    }

    mutating func applySuggestionEdit(
        title: String,
        description: String?,
        suggestionID: String,
        attachments: [URL],
        for questionID: String
    ) {
        ensureDraft(for: questionID)
        drafts[questionID]?.suggestions[suggestionID] = SuggestionDraftState(
            title: title,
            description: description,
            isEdited: true,
            attachmentURLs: Self.deduplicated(attachments)
        )
        if questionType(for: questionID) == .multipleChoice {
            if drafts[questionID]?.selectedSuggestionIDs.contains(suggestionID) != true {
                drafts[questionID]?.selectedSuggestionIDs.append(suggestionID)
            }
        } else {
            drafts[questionID]?.selectedSuggestionIDs = [suggestionID]
        }
    }

    mutating func addAttachments(_ urls: [URL], for questionID: String) {
        ensureDraft(for: questionID)
        let current = drafts[questionID]?.attachmentURLs ?? []
        drafts[questionID]?.attachmentURLs = Self.deduplicated(current + urls)
    }

    mutating func setAttachments(_ urls: [URL], for questionID: String) {
        ensureDraft(for: questionID)
        drafts[questionID]?.attachmentURLs = Self.deduplicated(urls)
    }

    mutating func removeAttachment(_ url: URL, for questionID: String) {
        ensureDraft(for: questionID)
        let path = url.standardizedFileURL.path
        drafts[questionID]?.attachmentURLs.removeAll { $0.standardizedFileURL.path == path }
    }

    mutating func removeEditedSuggestionAttachment(
        _ url: URL,
        suggestionID: String,
        for questionID: String
    ) {
        ensureDraft(for: questionID)
        let path = url.standardizedFileURL.path
        drafts[questionID]?.suggestions[suggestionID]?.attachmentURLs.removeAll {
            $0.standardizedFileURL.path == path
        }
    }

    func submissions(questionIDs: [String]) -> [QuestionSubmission] {
        questionIDs.map { questionID in
            let value = draft(for: questionID)
            let selectedAnswers = value.selectedSuggestionIDs.compactMap {
                value.suggestions[$0]?.answer
            }
            let selection = selectedAnswers.joined(separator: ", ")
            let note = value.freeformText.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer: String?
            if questionType(for: questionID) == .multipleChoice,
               !selection.isEmpty,
               !note.isEmpty
            {
                answer = "\(selection)\n\nAdditional note: \(note)"
            } else {
                let combined = selection.isEmpty ? note : selection
                answer = combined.isEmpty ? nil : combined
            }
            let selectedAttachments = value.selectedSuggestionIDs.flatMap {
                value.suggestions[$0]?.attachmentURLs ?? []
            }
            let selectedSuggestions = value.selectedSuggestionIDs.compactMap { suggestionID in
                value.suggestions[suggestionID].map {
                    TTSQuestionDraftSuggestion(
                        id: suggestionID,
                        title: $0.title,
                        description: $0.description
                    )
                }
            }
            return QuestionSubmission(
                questionID: questionID,
                answer: answer,
                suggestionIDs: value.selectedSuggestionIDs,
                selectedSuggestions: selectedSuggestions,
                attachmentURLs: Self.deduplicated(
                    value.attachmentURLs + selectedAttachments
                ).map(\.standardizedFileURL.path)
            )
        }
    }

    mutating func reset() {
        selectedQuestionID = nil
        drafts = [:]
        questionTypes = [:]
    }

    private mutating func ensureDraft(for questionID: String) {
        if drafts[questionID] == nil {
            drafts[questionID] = QuestionDraftState()
        }
    }

    private func questionType(for questionID: String) -> TTSQuestionType {
        questionTypes[questionID] ?? .singleChoice
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}

private struct AnswerEditorContext: Identifiable {
    enum Kind {
        case freeform
        case suggestion(String)
    }

    let questionID: String
    let kind: Kind
    let existingTitle: String?
    let existingDescription: String
    let existingAttachments: [URL]

    var id: String {
        switch kind {
        case .freeform: "\(questionID)::freeform"
        case let .suggestion(id): "\(questionID)::\(id)"
        }
    }

    var isSuggestion: Bool {
        if case .suggestion = kind { return true }
        return false
    }
}

private struct ImmediateClickTarget: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context _: Context) -> ImmediateClickNSView {
        ImmediateClickNSView(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: ImmediateClickNSView, context _: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class ImmediateClickNSView: NSView {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void

    init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            onSingleClick()
        } else if event.clickCount == 2 {
            onDoubleClick()
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
private final class AnswerEditorPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var parentWindow: NSWindow?

    func present(
        context: AnswerEditorContext,
        onSave: @escaping (String?, String, [URL]) -> Void
    ) {
        cancel()
        let parent = NSApp.keyWindow
        let editor = AnswerEditorView(
            context: context,
            onCancel: { [weak self] in self?.cancel() },
            onDone: { [weak self] title, description, attachments in
                onSave(title, description, attachments)
                self?.cancel()
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = context.isSuggestion ? "Edit suggestion" : "Write your answer"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: editor)
        panel.minSize = NSSize(width: 520, height: 360)

        let controller = NSWindowController(window: panel)
        windowController = controller
        parentWindow = parent
        if let parent {
            let screenFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
            let proposed = NSPoint(
                x: min(parent.frame.maxX + 16, screenFrame.maxX - panel.frame.width),
                y: min(parent.frame.maxY - panel.frame.height, screenFrame.maxY - panel.frame.height)
            )
            panel.setFrameOrigin(NSPoint(
                x: max(screenFrame.minX, proposed.x),
                y: max(screenFrame.minY, proposed.y)
            ))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        controller.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        guard let panel = windowController?.window else { return }
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
        windowController = nil
        parentWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        parentWindow?.removeChildWindow(panel)
        windowController = nil
        parentWindow = nil
    }
}

private struct AnswerEditorView: View {
    private enum Field: Hashable {
        case title
        case body
    }

    let context: AnswerEditorContext
    let onCancel: () -> Void
    let onDone: (String?, String, [URL]) -> Void
    @State private var title: String
    @State private var bodyText: String
    @State private var attachments: [URL]
    @State private var isDropTarget = false
    @FocusState private var focusedField: Field?

    init(
        context: AnswerEditorContext,
        onCancel: @escaping () -> Void,
        onDone: @escaping (String?, String, [URL]) -> Void
    ) {
        self.context = context
        self.onCancel = onCancel
        self.onDone = onDone
        _title = State(initialValue: context.existingTitle ?? "")
        _bodyText = State(initialValue: context.existingDescription)
        _attachments = State(initialValue: context.existingAttachments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    if context.isSuggestion {
                        TextField("Suggestion title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold))
                            .focused($focusedField, equals: .title)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                        Divider().padding(.horizontal, 20)
                    }

                    TextEditor(text: $bodyText)
                        .font(.system(size: 17))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                if isDropTarget {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isDropTarget
                    ? Color.accentColor.opacity(0.08)
                    : Color.clear
            )
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                addFiles(files)
                return !files.isEmpty
            } isTargeted: { isDropTarget = $0 }

            Divider()

            HStack(spacing: 8) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    addFiles(pickFiles())
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Attach files")
                .accessibilityLabel("Attach files")

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(attachments, id: \.standardizedFileURL.path) { url in
                                HStack(spacing: 4) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Button {
                                        attachments.removeAll {
                                            $0.standardizedFileURL.path == url.standardizedFileURL.path
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                                }
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: 280)
                }
                Spacer()
                Button("Done") {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDone(
                        context.isSuggestion ? trimmedTitle : nil,
                        bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachments
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(context.isSuggestion && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 680, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = context.isSuggestion ? .title : .body }
    }

    private func addFiles(_ urls: [URL]) {
        var paths = Set(attachments.map(\.standardizedFileURL.path))
        attachments.append(contentsOf: urls.filter { paths.insert($0.standardizedFileURL.path).inserted })
    }

    private func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach files to your answer"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}

private extension String {
    var nonemptyValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct NowSpeakingHUDView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: NowSpeakingPresentation
    @ObservedObject var sessionOpener: AgentSessionOpener
    @ObservedObject var playerPreferencesStore: PlayerPreferencesStore
    let isWindowedMode: Bool
    let onToggleMiniPlayer: () -> Void
    @State private var questionComposer = QuestionComposerModel()
    @StateObject private var answerEditorPresenter = AnswerEditorPresenter()
    @State private var isAnswerDropTarget = false
    @State private var primaryMessageContentHeight: CGFloat = 150
    @State private var previewPlaybackOffset: TimeInterval = 0
    @State private var isQuickSettingsPresented = false

    var body: some View {
        if let item = displayedItem {
            let accent = WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
            VStack(alignment: .leading, spacing: presentation.isExpanded ? 12 : 8) {
                if item.isQuestion {
                    questionPrompt(item: item, accent: accent)
                } else {
                    summary(item: item, accent: accent)

                    if presentation.isExpanded {
                        if isPreviewingPending {
                            Divider().overlay(Color.white.opacity(0.11))
                            ReadAlongTranscriptView(
                                text: item.text,
                                timings: item.wordTimings,
                                currentTime: 0,
                                duration: 0,
                                accent: accent,
                                onSeek: { _ in }
                            )
                            .transition(.opacity)
                            Divider().overlay(Color.white.opacity(0.11))
                            pendingPreviewStatus(for: item)
                        } else {
                            if !item.briefAttachments.isEmpty {
                                attachmentStrip(item: item, accent: accent)
                            }
                            Divider().overlay(Color.white.opacity(0.11))
                            if let attachment = selectedAttachment(for: item) {
                                attachmentPreview(attachment, item: item, accent: accent)
                                    .transition(.opacity)
                            } else {
                                ReadAlongTranscriptView(
                                    text: item.text,
                                    timings: item.wordTimings,
                                    currentTime: playbackTime,
                                    duration: playbackDuration,
                                    accent: accent,
                                    onSeek: { seek(item: item, to: $0) }
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            Divider().overlay(Color.white.opacity(0.11))
                            timeline(accent: accent)
                            controls(item: item, accent: accent)
                        }
                    } else {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(accent)
                            .controlSize(.mini)
                            .accessibilityLabel("Playback progress")
                    }
                }
            }
            .padding(.horizontal, presentation.isExpanded ? 18 : 14)
            .padding(.vertical, presentation.isExpanded ? 16 : 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(PlayerSurfaceStyle(isWindowedMode: isWindowedMode, accent: accent))
            .onHover { presentation.updateHover($0) }
            .animation(.easeInOut(duration: 0.2), value: presentation.isExpanded)
            .onChange(of: item.id) { _ in
                answerEditorPresenter.cancel()
                primaryMessageContentHeight = 150
                previewPlaybackOffset = 0
                questionComposer.reset()
                prepareComposer(for: item)
            }
            .onAppear {
                prepareComposer(for: item)
            }
            .onDisappear { answerEditorPresenter.cancel() }
            .overlay {
                if presentation.isExpanded, !isWindowedMode {
                    PlayerResizeRegions()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if presentation.isExpanded, !isWindowedMode {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(11)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(
                "\(isPreviewingPending ? "Pending update" : "Now speaking"). \(item.nowSpeakingTitle). \(item.nowSpeakingContext)"
            )
        } else if isWindowedMode {
            PlayerHistoryView(controller: controller, presentation: presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func questionPrompt(item: TTSItem, accent: Color) -> some View {
        let questions = displayQuestions(for: item)
        let current = selectedQuestion(in: questions)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.subjectLabel ?? "Questions from \(item.displayAgent)")
                        .font(.headline)
                    Text([item.displayAgent, item.workspaceDisplayLabel].compactMap(\.self).joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if sessionOpener.canOpen(rawIdentifier: item.iTermSessionID) {
                    Button {
                        sessionOpener.open(rawIdentifier: item.iTermSessionID)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open agent session")
                    .accessibilityLabel("Open agent session")
                }

            }

            if let primaryMessage = item.primaryMessage?.nonemptyValue {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Update")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ReadAlongTranscriptView(
                        text: primaryMessage,
                        timings: item.wordTimings,
                        currentTime: playbackTime,
                        duration: playbackDuration,
                        accent: accent,
                        onSeek: { seek(item: item, to: $0) },
                        onContentHeightChange: { height in
                            guard abs(primaryMessageContentHeight - height) > 1 else { return }
                            primaryMessageContentHeight = height
                        }
                    )
                    .frame(height: min(max(primaryMessageContentHeight, 72), 420))
                    .accessibilityLabel("Primary message")
                }
            }

            if !item.briefAttachments.isEmpty {
                contextAttachmentRow(
                    item.briefAttachments,
                    label: "Update attachments",
                    item: item,
                    accent: accent
                )
            }

            if questions.count > 1 {
                questionTabs(questions, accent: accent)
            }

            if let question = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(question.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            if let description = question.description?.nonemptyValue {
                                Text(description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let attachments = question.attachments, !attachments.isEmpty {
                            contextAttachmentRow(
                                attachments,
                                label: "Question context",
                                item: item,
                                accent: accent
                            )
                        }

                        if question.status == .pending, item.isPendingQuestion {
                            pendingQuestionContent(question, item: item, accent: accent)
                        } else if let response = question.response {
                            sentResponse(response, accent: accent)
                        } else if question.status == .skipped {
                            Label("Skipped", systemImage: "forward.end.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Question \(question.title)")
            }

            if item.isPendingQuestion {
                HStack(spacing: 10) {
                    Text("All questions are optional. Blanks will be skipped.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        submitAnswers(for: item, questions: questions)
                    } label: {
                        Label(questions.count > 1 ? "Send answers" : "Send", systemImage: "arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit(item: item, questions: questions))
                    .opacity(canSubmit(item: item, questions: questions) ? 1 : 0.45)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityHint("Submits every tab together; unanswered questions are skipped")
                }
            }

            if !isPreviewingPending || QuestionAudioReview.canReplay(item) {
                Divider().overlay(Color.white.opacity(0.11))
                timeline(accent: accent)
                controls(item: item, accent: accent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from \(item.displayAgent)")
    }

    @ViewBuilder
    private func pendingQuestionContent(
        _ question: TTSQuestion,
        item: TTSItem,
        accent: Color
    ) -> some View {
        let draft = questionComposer.draft(for: question.id)
        if let suggestions = question.suggestions, !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(question.type == .multipleChoice ? "Choose any that apply" : "Choose one")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    suggestionCard(
                        suggestion,
                        id: suggestionID(suggestion, index: index),
                        question: question,
                        item: item,
                        selected: draft.selectedSuggestionIDs.contains(suggestionID(suggestion, index: index)),
                        accent: accent
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggested answers")
        }

        let answerAttachments = questionComposer.draft(for: question.id).attachmentURLs
        VStack(alignment: .leading, spacing: 6) {
            Text(question.type == .multipleChoice ? "Additional note" : "Your answer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 6) {
                Button {
                    openAnswerEditor(for: question)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(draft.freeformText.nonemptyValue ?? "Write anything…")
                            .font(.system(size: 15))
                            .foregroundStyle(draft.freeformText.nonemptyValue == nil ? .secondary : .primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open answer editor for \(question.title)")

                Button {
                    questionComposer.addAttachments(pickFiles(), for: question.id)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help("Attach files")
                .accessibilityLabel("Attach files to this answer")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                isAnswerDropTarget ? accent.opacity(0.11) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        isAnswerDropTarget ? accent : accent.opacity(0.22),
                        lineWidth: isAnswerDropTarget ? 1.4 : 0.8
                    )
            }
            .overlay(alignment: .bottomLeading) {
                if isAnswerDropTarget {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                questionComposer.addAttachments(files, for: question.id)
                return !files.isEmpty
            } isTargeted: { isAnswerDropTarget = $0 }
            .accessibilityLabel("Freeform answer for \(question.title)")

            if !answerAttachments.isEmpty {
                answerAttachmentChips(
                    answerAttachments,
                    questionID: question.id,
                    suggestionID: nil,
                    accent: accent
                )
            }
        }
    }

    private func questionTabs(_ questions: [TTSQuestion], accent: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    let selected = questionComposer.selectedQuestionID == question.id
                    let answered = !questionComposer.submissions(questionIDs: [question.id])[0].isSkipped
                    Button {
                        questionComposer.selectQuestion(question.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .frame(width: 18, height: 18)
                                .background(selected ? Color.black.opacity(0.16) : accent.opacity(0.13), in: Circle())
                            Text(question.shortTitle?.nonemptyValue ?? question.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if answered {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.primary)
                        .background(
                            selected ? accent : Color.white.opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Question \(index + 1): \(question.title)")
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("Question tabs")
    }

    private func suggestionCard(
        _ suggestion: TTSSuggestion,
        id: String,
        question: TTSQuestion,
        item: TTSItem,
        selected: Bool,
        accent: Color
    ) -> some View {
        let draft = questionComposer.draft(for: question.id)
        let suggestionDraft = draft.suggestion(id)
        let displayTitle = suggestionDraft?.isEdited == true
            ? suggestionDraft?.title ?? suggestion.title
            : suggestion.title
        let displayDescription = suggestionDraft?.isEdited == true
            ? suggestionDraft?.description
            : suggestion.description
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    questionComposer.selectSuggestion(
                        id: id,
                        title: displayTitle,
                        description: displayDescription,
                        for: question.id
                    )
                } label: {
                    Image(systemName: choiceSymbol(for: question.type, selected: selected))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? accent : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(question.type == .multipleChoice && selected ? "Deselect" : "Select") \(displayTitle)"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = displayDescription?.nonemptyValue {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay {
                    ImmediateClickTarget(
                        onSingleClick: {
                            questionComposer.selectSuggestion(
                                id: id,
                                title: displayTitle,
                                description: displayDescription,
                                for: question.id
                            )
                        },
                        onDoubleClick: {
                            openSuggestionEditor(suggestion, id: id, questionID: question.id)
                        }
                    )
                }

                Button {
                    openSuggestionEditor(suggestion, id: id, questionID: question.id)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Personalize this suggestion")
                .accessibilityLabel("Personalize \(displayTitle)")
            }

            if let attachments = suggestion.attachments, !attachments.isEmpty {
                compactAttachmentButtons(attachments, item: item, accent: accent)
            }

            if let suggestionDraft, suggestionDraft.isEdited, !suggestionDraft.attachmentURLs.isEmpty {
                answerAttachmentChips(
                    suggestionDraft.attachmentURLs,
                    questionID: question.id,
                    suggestionID: id,
                    accent: accent
                )
            }
        }
        .padding(11)
        .background(
            selected ? accent.opacity(0.16) : Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? accent : accent.opacity(0.14), lineWidth: selected ? 1.2 : 0.7)
        }
        .accessibilityLabel(displayTitle)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(
            question.type == .multipleChoice
                ? "Click to toggle this option. Double-click or use the pencil to personalize."
                : "Click to select without changing the freeform answer. Double-click or use the pencil to personalize."
        )
    }

    private func answerAttachmentChips(
        _ urls: [URL],
        questionID: String,
        suggestionID: String?,
        accent: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(urls, id: \.standardizedFileURL.path) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                        Button {
                            if let suggestionID {
                                questionComposer.removeEditedSuggestionAttachment(
                                    url,
                                    suggestionID: suggestionID,
                                    for: questionID
                                )
                            } else {
                                questionComposer.removeAttachment(url, for: questionID)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.1), in: Capsule())
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func contextAttachmentRow(
        _ attachments: [TTSAttachment],
        label: String,
        item: TTSItem,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            compactAttachmentButtons(attachments, item: item, accent: accent)
        }
    }

    private func compactAttachmentButtons(
        _ attachments: [TTSAttachment],
        item: TTSItem,
        accent: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    Button {
                        openSupportingAttachment(attachment, item: item)
                    } label: {
                        Label(attachment.label, systemImage: attachmentSymbol(attachment))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help(attachmentHelp(attachment))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func sentResponse(_ response: TTSResponse, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Answer sent")
                    .font(.subheadline.weight(.semibold))
                if let answer = response.answer.nonemptyValue {
                    Text(answer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let attachments = response.attachments, !attachments.isEmpty {
                    ForEach(attachments) { attachment in
                        Label(attachment.sourceFile, systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func displayQuestions(for item: TTSItem) -> [TTSQuestion] {
        if let questions = item.questions, !questions.isEmpty { return questions }
        return [TTSQuestion(
            id: "legacy::\(item.id)",
            title: item.text,
            suggestions: item.suggestions,
            status: item.questionStatus ?? .pending,
            response: item.response
        )]
    }

    private func selectedQuestion(in questions: [TTSQuestion]) -> TTSQuestion? {
        let selected = questionComposer.selectedQuestionID ?? questions.first?.id
        return questions.first { $0.id == selected } ?? questions.first
    }

    private func prepareComposer(for item: TTSItem) {
        questionComposer.prepare(questions: displayQuestions(for: item).map {
            QuestionChoiceConfiguration(id: $0.id, type: $0.type)
        })
    }

    private func suggestionID(_ suggestion: TTSSuggestion, index: Int) -> String {
        suggestion.id?.nonemptyValue ?? "suggestion-\(index)"
    }

    private func openSuggestionEditor(
        _ suggestion: TTSSuggestion,
        id: String,
        questionID: String
    ) {
        let draft = questionComposer.draft(for: questionID)
        let suggestionDraft = draft.suggestion(id)
        presentAnswerEditor(AnswerEditorContext(
            questionID: questionID,
            kind: .suggestion(id),
            existingTitle: suggestionDraft?.title ?? suggestion.title,
            existingDescription: suggestionDraft?.description ?? suggestion.description ?? "",
            existingAttachments: suggestionDraft?.attachmentURLs ?? []
        ))
    }

    private func openAnswerEditor(for question: TTSQuestion) {
        let draft = questionComposer.draft(for: question.id)
        presentAnswerEditor(AnswerEditorContext(
            questionID: question.id,
            kind: .freeform,
            existingTitle: nil,
            existingDescription: draft.freeformText,
            existingAttachments: draft.attachmentURLs
        ))
    }

    private func presentAnswerEditor(_ context: AnswerEditorContext) {
        answerEditorPresenter.present(context: context) { title, description, attachments in
            switch context.kind {
            case .freeform:
                questionComposer.updateDraft(description, for: context.questionID)
                questionComposer.setAttachments(attachments, for: context.questionID)
            case let .suggestion(suggestionID):
                guard let title else { return }
                questionComposer.applySuggestionEdit(
                    title: title,
                    description: description.nonemptyValue,
                    suggestionID: suggestionID,
                    attachments: attachments,
                    for: context.questionID
                )
            }
        }
    }

    private func choiceSymbol(for type: TTSQuestionType, selected: Bool) -> String {
        switch (type, selected) {
        case (.singleChoice, true): "largecircle.fill.circle"
        case (.singleChoice, false): "circle"
        case (.multipleChoice, true): "checkmark.square.fill"
        case (.multipleChoice, false): "square"
        }
    }

    private func openSupportingAttachment(_ attachment: TTSAttachment, item: TTSItem) {
        if attachment.kind == .narratedText || attachment.kind == .audio, attachment.isPlayable {
            controller.playAttachment(attachment, from: item)
        } else {
            controller.openAttachment(attachment)
        }
    }

    private func canSubmit(item: TTSItem, questions: [TTSQuestion]) -> Bool {
        if item.questions?.isEmpty == false { return true }
        return questionComposer.submissions(questionIDs: questions.map(\.id)).first?.isSkipped == false
    }

    private func submitAnswers(for item: TTSItem, questions: [TTSQuestion]) {
        answerEditorPresenter.cancel()
        let submissions = questionComposer.submissions(questionIDs: questions.map(\.id))
        if item.questions?.isEmpty == false {
            controller.submitBundle(
                item,
                drafts: submissions.map { submission in
                    TTSQuestionDraft(
                        questionID: submission.questionID,
                        answer: submission.answer ?? "",
                        suggestionID: submission.suggestionID,
                        attachmentURLs: submission.attachmentURLs.map(URL.init(fileURLWithPath:)),
                        interaction: interaction(for: submission),
                        suggestionIDs: submission.suggestionIDs,
                        selectedSuggestions: submission.selectedSuggestions
                    )
                }
            )
        } else if let submission = submissions.first, let answer = submission.answer {
            let suggestionIndex = item.suggestions?.enumerated().first {
                suggestionID($0.element, index: $0.offset) == submission.suggestionID
            }?.offset
            controller.answer(item, text: answer, suggestionIndex: suggestionIndex)
        }
    }

    private func interaction(for submission: QuestionSubmission) -> String? {
        guard !submission.suggestionIDs.isEmpty else {
            return submission.answer == nil ? nil : "freeform"
        }
        let draft = questionComposer.draft(for: submission.questionID)
        let edited = submission.suggestionIDs.contains {
            draft.suggestion($0)?.isEdited == true
        }
        return edited ? "suggestion_edited" : "suggestion"
    }

    private func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach files to your answer"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func summary(item: TTSItem, accent: Color) -> some View {
        HStack(alignment: .center, spacing: presentation.isExpanded ? 13 : 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: presentation.isExpanded ? 22 : 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(
                    width: presentation.isExpanded ? 40 : 32,
                    height: presentation.isExpanded ? 40 : 32
                )
                .background(accent.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: presentation.isExpanded ? 5 : 3) {
                Text(item.nowSpeakingTitle)
                    .font(presentation.isExpanded ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(presentation.isExpanded ? 2 : 1)

                Text(item.displayAgent)
                    .font(presentation.isExpanded ? .subheadline.weight(.medium) : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let workspaceLabel = item.workspaceDisplayLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .foregroundStyle(accent.opacity(0.9))
                            .accessibilityHidden(true)
                        Text(workspaceLabel)
                            .fontWeight(.semibold)
                            .truncationMode(.middle)
                        if let worktreeLabel = item.workspaceWorktreeLabel {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(worktreeLabel)
                                .truncationMode(.middle)
                        }
                    }
                    .font(presentation.isExpanded ? .caption : .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        item.workspaceWorktreeLabel.map {
                            "Project \(workspaceLabel), worktree \($0)"
                        } ?? "Project \(workspaceLabel)"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !presentation.isExpanded, !item.briefAttachments.isEmpty {
                Label("\(item.briefAttachments.count)", systemImage: "paperclip")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .accessibilityLabel("\(item.briefAttachments.count) attachments")
            }

            if !isWindowedMode {
                Button(action: onToggleMiniPlayer) {
                    Image(
                        systemName: presentation.isExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.system(size: presentation.isExpanded ? 14 : 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help(presentation.isExpanded ? "Use mini player" : "Expand player")
                .accessibilityLabel(presentation.isExpanded ? "Use mini player" : "Expand player")
            }

            if sessionOpener.canOpen(rawIdentifier: item.iTermSessionID) {
                Button {
                    sessionOpener.open(rawIdentifier: item.iTermSessionID)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: presentation.isExpanded ? 14 : 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Open agent session")
                .accessibilityLabel("Open agent session")
            }

        }
    }

    private func pendingPreviewStatus(for item: TTSItem) -> some View {
        HStack(spacing: 8) {
            if item.status == .generating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "clock")
            }
            Text(item.status == .generating ? "Generating audio…" : "Audio ready — waiting to play")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.status == .generating ? "Generating audio" : "Audio ready and waiting to play")
    }

    private func attachmentStrip(item: TTSItem, accent: Color) -> some View {
        HStack(spacing: 8) {
            if item.isAttachmentPlayback {
                Button {
                    presentation.selectAttachment(nil)
                    controller.returnToParent(from: item)
                } label: {
                    Label("Main update", systemImage: "arrow.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Return to the main message")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(item.briefAttachments) { attachment in
                        attachmentButton(attachment, item: item, accent: accent)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }

    private func attachmentButton(
        _ attachment: TTSAttachment,
        item: TTSItem,
        accent: Color
    ) -> some View {
        let selected = presentation.selectedAttachmentID == attachment.id
            || item.attachmentID == attachment.id
        return Button {
            switch attachment.kind {
            case .image:
                presentation.selectAttachment(
                    selected ? nil : attachment.id,
                    image: selected ? nil : NSImage(contentsOfFile: attachment.sourceFile)
                )
            case .diagram:
                presentation.selectAttachment(
                    selected ? nil : attachment.id,
                    text: selected ? nil : (attachment.displayText ?? attachment.text)
                )
            case .narratedText, .audio:
                if attachment.isPlayable {
                    if item.isAttachmentPlayback,
                       item.attachmentID == attachment.id
                    {
                        presentation.selectAttachment(nil)
                    } else {
                        presentation.selectAttachment(
                            attachment.id,
                            text: attachment.displayText
                        )
                        controller.playAttachment(attachment, from: item)
                    }
                } else {
                    presentation.selectAttachment(
                        attachment.id,
                        text: attachment.displayText
                    )
                }
            case .file:
                controller.openAttachment(attachment)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: attachmentSymbol(attachment))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.black.opacity(0.76) : accent)

                Text(attachment.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if attachment.status == .preparing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.66)
                        .frame(width: 10, height: 10)
                } else if attachment.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? accent : Color.white.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? accent.opacity(0) : accent.opacity(0.18), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .help(attachmentHelp(attachment))
        .accessibilityLabel(attachment.label)
        .accessibilityValue(attachment.status.rawValue)
    }

    @ViewBuilder
    private func attachmentPreview(
        _ attachment: TTSAttachment,
        item: TTSItem,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    presentation.selectAttachment(nil)
                } label: {
                    Label("Main transcript", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)

                Text(attachment.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Button {
                    controller.openAttachment(attachment)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open attachment")
            }

            if attachment.kind == .diagram,
               let source = presentation.selectedAttachmentText ?? attachment.text
            {
                MermaidDiagramView(
                    source: source,
                    accentHue: WorkspaceAccent.paletteIndex(forWorkspacePath: item.workspacePath)
                )
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if attachment.kind == .image,
                      let image = presentation.selectedAttachmentImage
            {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if let text = presentation.selectedAttachmentText ?? attachment.text {
                ScrollView {
                    Text(markdownPreview(text))
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))

                if attachment.status == .preparing {
                    Label("Preparing narration…", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if attachment.isPlayable {
                    Button {
                        controller.playAttachment(attachment, from: item)
                    } label: {
                        Label("Play narration", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(accent, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                } else if let error = attachment.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "doc")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(accent)
                    Text("Preview unavailable")
                        .font(.headline)
                    Text("Open the attachment in its default app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectedAttachment(for item: TTSItem) -> TTSAttachment? {
        guard let selectedID = presentation.selectedAttachmentID else { return nil }
        return item.briefAttachments.first(where: { $0.id == selectedID })
    }

    private func attachmentSymbol(_ attachment: TTSAttachment) -> String {
        switch attachment.kind {
        case .narratedText: attachment.isPlayable ? "waveform" : "doc.text"
        case .image: "photo"
        case .diagram: "flowchart"
        case .audio: "speaker.wave.2"
        case .file: "paperclip"
        }
    }

    private func attachmentHelp(_ attachment: TTSAttachment) -> String {
        switch (attachment.kind, attachment.status) {
        case (_, .failed): attachment.error ?? "Attachment preparation failed"
        case (.narratedText, .preparing): "Read while narration is prepared"
        case (.narratedText, .ready), (.audio, .ready): "Play \(attachment.label)"
        case (.image, _), (.diagram, _): "Preview \(attachment.label)"
        case (.file, _): "Open \(attachment.label)"
        case (.audio, .preparing): "Preparing audio"
        }
    }

    private func markdownPreview(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(value)
    }

    private func timeline(accent: Color) -> some View {
        VStack(spacing: 3) {
            Slider(
                value: Binding(
                    get: { playbackTime },
                    set: { newValue in
                        if isPreviewingPending {
                            previewPlaybackOffset = newValue
                        } else if isLingering {
                            presentation.lingeringTime = newValue
                        } else {
                            controller.seek(to: newValue)
                        }
                    }
                ),
                in: 0 ... max(playbackDuration, 1),
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    if isPreviewingPending, let item = pendingPreviewItem {
                        controller.replay(item, startingAt: previewPlaybackOffset)
                    } else if isLingering, let item = presentation.lingeringItem {
                        controller.replay(item, startingAt: presentation.lingeringTime)
                    }
                }
            )
            .tint(accent)
            .controlSize(.small)
            .accessibilityLabel("Playback position")

            HStack {
                Text(formattedTime(playbackTime))
                Spacer()
                Text("-" + formattedTime(max(0, playbackDuration - playbackTime)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(item: TTSItem, accent: Color) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                if isWindowedMode {
                    quickSettingsButton(accent: accent)
                }
                playbackRateButton(item: item, accent: accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                controlButton(symbol: "gobackward.15", label: "Back 15 seconds", accent: accent) {
                    if isLingering || isPreviewingPending {
                        controller.replay(item, startingAt: max(0, playbackTime - 15))
                    } else {
                        controller.rewind()
                    }
                }
                controlButton(
                    symbol: isLingering || isPreviewingPending
                        ? "arrow.counterclockwise"
                        : (controller.isPaused ? "play.fill" : "pause.fill"),
                    label: isLingering || isPreviewingPending
                        ? "Replay"
                        : (controller.isPaused ? "Resume" : "Pause"),
                    accent: accent,
                    prominent: true
                ) {
                    if isLingering || isPreviewingPending {
                        controller.replay(item, startingAt: 0)
                    } else {
                        controller.togglePause()
                    }
                }
                controlButton(symbol: "goforward.15", label: "Forward 15 seconds", accent: accent) {
                    if isLingering || isPreviewingPending {
                        controller.replay(
                            item,
                            startingAt: min(playbackDuration, playbackTime + 15)
                        )
                    } else {
                        controller.forward()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            nextInQueueIndicator
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func quickSettingsButton(accent: Color) -> some View {
        Button {
            isQuickSettingsPresented.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Player floatness and transparency")
        .accessibilityLabel("Player floatness and transparency")
        .popover(isPresented: $isQuickSettingsPresented, arrowEdge: .bottom) {
            QuickSettingsPopover(playerPreferencesStore: playerPreferencesStore)
        }
    }

    @ViewBuilder
    private var nextInQueueIndicator: some View {
        if let next = controller.nextQueuedItem {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("UP NEXT")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(.tertiary)
                    Text(next.nowSpeakingTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .help("Next: \(next.nowSpeakingTitle)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Up next: \(next.nowSpeakingTitle)")
        } else {
            Color.clear
                .frame(height: 34)
                .accessibilityHidden(true)
        }
    }

    private func playbackRateButton(item: TTSItem, accent: Color) -> some View {
        Button {
            controller.cyclePlaybackRate(for: item)
        } label: {
            Text(controller.playbackRateLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 42, height: 34)
                .background(accent.opacity(0.14), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(accent.opacity(0.28), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .help("Playback speed for \(item.voice). Click to change.")
        .accessibilityLabel("Playback speed for \(item.voice)")
        .accessibilityValue(controller.playbackRateLabel)
    }

    private func controlButton(
        symbol: String,
        label: String,
        accent: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 15, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.82) : Color.primary)
                .frame(width: prominent ? 38 : 34, height: prominent ? 38 : 34)
                .background(
                    prominent ? accent : Color.white.opacity(0.09),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var progress: Double {
        guard playbackDuration > 0 else { return 0 }
        return min(max(playbackTime / playbackDuration, 0), 1)
    }

    private var displayedItem: TTSItem? {
        let item = controller.currentItem ?? pendingPreviewItem ?? presentation.lingeringItem
        guard PlayerNavigationPolicy.shouldDisplay(
            itemID: item?.id,
            hiddenItemID: presentation.hiddenItemID
        ) else { return nil }
        return item
    }

    private var pendingPreviewItem: TTSItem? {
        guard let preview = presentation.pendingPreviewItem else { return nil }
        return controller.items.first(where: { $0.id == preview.id }) ?? preview
    }

    private var isPreviewingPending: Bool {
        controller.currentItem == nil && pendingPreviewItem != nil
    }

    private var isLingering: Bool {
        controller.currentItem == nil && presentation.lingeringItem != nil
    }

    private var playbackTime: TimeInterval {
        if isPreviewingPending { return previewPlaybackOffset }
        return isLingering ? presentation.lingeringTime : controller.currentTime
    }

    private var playbackDuration: TimeInterval {
        if isPreviewingPending { return pendingPreviewItem?.duration ?? 0 }
        return isLingering ? presentation.lingeringDuration : controller.duration
    }

    private var statusSymbol: String {
        if isPreviewingPending {
            return pendingPreviewItem?.status == .generating ? "ellipsis" : "clock"
        }
        if isLingering { return "arrow.counterclockwise" }
        return controller.isPaused ? "pause.fill" : "waveform"
    }

    private func seek(item: TTSItem, to time: TimeInterval) {
        if isLingering || isPreviewingPending {
            controller.replay(item, startingAt: time)
        } else {
            controller.seek(to: time)
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerHistoryView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: NowSpeakingPresentation

    var body: some View {
        Group {
            if filteredItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(emptyStateTitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredItems.prefix(60)) { item in
                    PlayerHistoryRow(
                        item: item,
                        action: {
                            presentation.revealForDirectSelection(itemID: item.id)
                            if item.status == .generating || item.isPendingQuestion {
                                presentation.previewPendingItem(item)
                            } else {
                                controller.playNow(item)
                            }
                        },
                        onRetry: { controller.retryGeneration(item) },
                        isRetrying: controller.isRetrying(item),
                        generationProgress: controller.generationProgress(for: item),
                        timestampNow: controller.historyTimestampNow,
                        onArchive: { controller.setArchived(!item.archived, for: item) }
                    )
                        .listRowInsets(EdgeInsets(
                            top: 8,
                            leading: 16,
                            bottom: item.status == .generating ? 0 : 8,
                            trailing: 16
                        ))
                        .listRowSeparator(item.status == .generating ? .hidden : .visible)
                        .listRowBackground(
                            GenerationProgressRowBackground(
                                item: item,
                                progress: controller.generationProgress(for: item)
                            )
                        )
                }
                .listStyle(.plain)
            }
        }
    }

    private var historyItems: [TTSItem] {
        presentation.isViewingArchive ? controller.archivedHistoryItems : controller.activeHistoryItems
    }

    private var filteredItems: [TTSItem] {
        historyItems.filter { item in
            let matchesProject = presentation.historyProjectFilter.map { item.workspaceName == $0 } ?? true
            return matchesProject && matchesSearch(item)
        }
    }

    private var emptyStateTitle: String {
        if !presentation.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching speech"
        }
        if presentation.isViewingArchive {
            return presentation.historyProjectFilter == nil ? "No archived speech" : "No archived speech for this project"
        }
        return presentation.historyProjectFilter == nil ? "No recent speech" : "No speech for this project"
    }

    private func matchesSearch(_ item: TTSItem) -> Bool {
        let query = presentation.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [item.nowSpeakingTitle, item.text, item.displayAgent, item.workspaceName]
            .compactMap(\.self)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct PlayerHistoryRow: View {
    let item: TTSItem
    let action: () -> Void
    let onRetry: () -> Void
    let isRetrying: Bool
    let generationProgress: Double
    let timestampNow: Date
    let onArchive: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            queueItemIndicator
            Button(action: action) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.displayAgent)
                            .font(.system(size: 16, weight: item.unheard ? .bold : .semibold))
                            .foregroundStyle(
                                WorkspaceAccent.color(forAgentName: item.displayAgent)
                                    .opacity(item.status == .generating ? 0.72 : 1)
                            )
                            .lineLimit(1)
                        if let projectName = item.workspaceName {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(projectName)
                                .font(.system(size: 16, weight: item.unheard ? .bold : .semibold))
                                .foregroundStyle(
                                    WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
                                        .opacity(item.status == .generating ? 0.72 : 1)
                                )
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(item.timestampLabel(now: timestampNow))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Text(summary)
                        .font(.system(size: 15, weight: item.unheard ? .semibold : .regular))
                        .foregroundStyle(summaryColor)
                        .lineLimit(1)
                }

                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.status == .failed || (item.status != .generating && !FileManager.default.fileExists(atPath: item.outputFile)))
            .opacity(item.status == .generating ? 0.78 : 1)
            .help(item.status == .generating ? "Open update while audio is generated" : "Play now")
            .accessibilityLabel(accessibilityLabel)

            if item.status == .generating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Generating audio")
            } else {
                VStack(alignment: .trailing, spacing: 7) {
                    if item.status == .failed {
                        Button(action: onRetry) {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 18, height: 18)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isRetrying)
                        .help(isRetrying ? "Retrying synthesis" : "Retry synthesis")
                        .accessibilityLabel(isRetrying ? "Retrying synthesis" : "Retry synthesis")
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.status != .generating {
                Button(role: item.archived ? nil : .destructive, action: onArchive) {
                    Label(
                        item.archived ? "Restore" : "Archive",
                        systemImage: item.archived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                .tint(item.archived ? .accentColor : .red)
            }
        }
    }

    private var detail: String {
        if item.status == .generating {
            return "Generating audio…"
        } else if item.status == .failed {
            return item.error.map { "Failed: \($0)" } ?? "Failed"
        }
        return item.text
    }

    @ViewBuilder
    private var queueItemIndicator: some View {
        if item.isPendingQuestion {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.orange, in: Circle())
                .shadow(color: Color.orange.opacity(0.28), radius: 4, y: 1)
                .help("Contains unanswered questions")
                .accessibilityLabel("Unanswered questions")
        } else if item.isQuestion {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(Color.purple.opacity(0.12), in: Circle())
                .help("Contains questions")
                .accessibilityLabel("Contains questions")
        } else {
            Circle()
                .fill(item.unheard ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .frame(width: 28, height: 28)
        }
    }

    private var summary: String {
        guard item.nowSpeakingTitle != detail else { return detail }
        return "\(item.nowSpeakingTitle) — \(detail)"
    }

    private var summaryColor: Color {
        item.status == .failed ? .secondary : .primary.opacity(0.84)
    }

    private var accessibilityLabel: String {
        let title = item.subjectLabel ?? item.text
        if item.isPendingQuestion { return "Answer needed for \(title)" }
        if item.isQuestion { return "Question item \(title)" }
        if item.status == .generating { return "Open pending update \(title)" }
        if item.status == .failed { return "Failed synthesis for \(title)" }
        return "Play now \(title)"
    }
}

private struct GenerationProgressRowBackground: View {
    let item: TTSItem
    let progress: Double

    var body: some View {
        if item.isPendingQuestion {
            Color.orange.opacity(0.075)
                .accessibilityHidden(true)
        } else if item.status == .generating {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.10))
                        Rectangle()
                            .fill(WorkspaceAccent.color(forWorkspacePath: item.workspacePath).opacity(0.82))
                            .frame(width: max(3, (geometry.size.width - 17) * progress))
                    }
                    .frame(height: 2)
                    .padding(.leading, 17)
                }
            }
            .accessibilityLabel("Generating audio")
        } else {
            Color.clear
        }
    }
}

private struct PlayerSurfaceStyle: ViewModifier {
    let isWindowedMode: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isWindowedMode {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content
                .hudSurface(accent: accent)
                .padding(8)
        }
    }
}

private struct QuickSettingsPopover: View {
    @ObservedObject var playerPreferencesStore: PlayerPreferencesStore

    private var floatnessMode: Binding<FloatnessMode> {
        Binding(
            get: { playerPreferencesStore.preferences.floatnessMode },
            set: { playerPreferencesStore.setFloatnessMode($0) }
        )
    }

    private var windowOpacity: Binding<Double> {
        Binding(
            get: { playerPreferencesStore.preferences.windowOpacity },
            set: { playerPreferencesStore.setWindowOpacity($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Floatness", systemImage: "pin")
                    .font(.headline)
                Picker("Floatness", selection: floatnessMode) {
                    ForEach(FloatnessMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("\"While playing\" keeps the window on top until a pending question is answered, skipped, or superseded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Transparency", systemImage: "circle.lefthalf.filled")
                        .font(.headline)
                    Spacer()
                    Text(String(
                        format: "%d%%",
                        Int((1.0 - playerPreferencesStore.preferences.windowOpacity) * 100)
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                Slider(value: windowOpacity, in: 0.2...1.0, step: 0.05)
                Text("Hovering the player returns it to fully opaque.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 280)
    }
}

private extension View {
    func hudSurface(accent: Color) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.26))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accent.opacity(0.055))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}
