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
        static let fadeSeconds: TimeInterval = 0.34
    }

    private static let historyToolbarIdentifier = NSToolbar.Identifier("TTSHistoryToolbar")
    private static let historyFilterItemIdentifier = NSToolbarItem.Identifier("TTSHistoryProjectFilter")
    private static let historySearchItemIdentifier = NSToolbarItem.Identifier("TTSHistorySearch")

    private let playbackController: PlaybackController
    private let preferencesStore: HUDPreferencesStore
    private let presentation: NowSpeakingPresentation
    private let sessionOpener: AgentSessionOpener
    private var panel: NSWindow
    private var windowedMode: Bool
    @Published private(set) var isPlayerVisible: Bool
    @Published private(set) var isWindowedMode: Bool
    private var playbackObservation: AnyCancellable?
    private var presentationObservation: AnyCancellable?
    private var screenObservation: AnyCancellable?
    private var moveObservation: AnyCancellable?
    private var resizeObservation: AnyCancellable?
    private var liveResizeEndObservation: AnyCancellable?
    private var closeObservation: AnyCancellable?
    private var lingerTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var geometrySaveTask: Task<Void, Never>?
    private var activeItemID: String?
    private var lastCurrentItem: TTSItem?
    private var lastDuration: TimeInterval = 0
    private var lingerCountdown = LingerCountdown(duration: Layout.lingerSeconds)
    private var observedHover = false
    private var observedMiniPlayer: Bool
    private var isFading = false
    private var historyFilterToolbarItem: NSMenuToolbarItem?

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

    init(
        controller: PlaybackController,
        preferencesStore: HUDPreferencesStore,
        sessionOpener: AgentSessionOpener = AgentSessionOpener()
    ) {
        playbackController = controller
        self.preferencesStore = preferencesStore
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
                let size = self.presentation.isExpanded
                    ? self.preferredExpandedSize
                    : Layout.compactSize
                self.configureResizeLimits(expanded: self.presentation.isExpanded)
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
            isWindowedMode: windowedMode,
            onToggleMiniPlayer: { [weak self] in self?.toggleMiniPlayer() },
            onHide: { [weak self] in self?.setPlayerVisible(false) }
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

        cancelLingerDismissal(resetCountdown: true, restoreOpacity: false)
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
        lastCurrentItem = nil
        if wasVisible {
            refresh()
        } else {
            updateActivationPolicy()
        }
    }

    func refresh() {
        updateHistoryFilterMenu()
        guard isPlayerVisible else {
            sessionOpener.clear()
            if panel.isVisible || activeItemID != nil {
                hide()
            }
            return
        }
        guard let item = playbackController.currentItem else {
            if windowedMode {
                sessionOpener.clear()
                showIdleIfNeeded()
            } else {
                sessionOpener.refresh(rawIdentifier: lastCurrentItem?.iTermSessionID)
                beginLingerIfNeeded()
            }
            return
        }

        if presentation.lingeringItem != nil || lingerTask != nil || isFading {
            cancelLingerDismissal(resetCountdown: true, restoreOpacity: true)
        }
        if presentation.lingeringItem != nil {
            presentation.lingeringItem = nil
        }
        if item.isAttachmentPlayback,
           presentation.selectedAttachmentID == item.attachmentID {
            presentation.selectAttachment(nil)
        }
        lastCurrentItem = item
        lastDuration = max(playbackController.duration, item.duration ?? 0)
        sessionOpener.refresh(rawIdentifier: item.iTermSessionID)

        if activeItemID != item.id {
            activeItemID = item.id
            if windowedMode, panel.isVisible {
                // Leave the window exactly where the user placed/sized it; just surface it.
                panel.orderFront(nil)
            } else {
                showPlayer()
            }
        } else if !panel.isVisible {
            showPlayer()
        }
    }

    func shutdown() {
        playbackObservation?.cancel()
        presentationObservation?.cancel()
        screenObservation?.cancel()
        moveObservation?.cancel()
        resizeObservation?.cancel()
        liveResizeEndObservation?.cancel()
        lingerTask?.cancel()
        fadeTask?.cancel()
        geometrySaveTask?.cancel()
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

    func toggleMiniPlayer() {
        let useMiniPlayer = !presentation.isMiniPlayer
        if useMiniPlayer && presentation.isExpanded {
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

    private func configureHistoryToolbar() {
        let toolbar = NSToolbar(identifier: Self.historyToolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        panel.toolbarStyle = .unified
        panel.toolbar = toolbar
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
        if presentation.lingeringItem != nil || lingerTask != nil || isFading {
            cancelLingerDismissal(resetCountdown: true, restoreOpacity: true)
        }
        presentation.lingeringItem = nil
        lastCurrentItem = nil
        activeItemID = nil
        guard !panel.isVisible else { return }
        showPlayer()
    }

    private func showPlayer() {
        configureResizeLimits(expanded: presentation.isExpanded)
        positionPanel(size: presentation.isExpanded ? preferredExpandedSize : Layout.compactSize)
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
            // Windowed mode is a normal window: show it opaque, no fade.
            panel.alphaValue = 1
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
        let expanded = presentation.isExpanded
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
        let miniPlayer = presentation.isMiniPlayer
        if miniPlayer != observedMiniPlayer {
            observedMiniPlayer = miniPlayer
            updateLayout(animated: true)
        }

        let isHovered = presentation.isHovered
        guard isHovered != observedHover else { return }
        observedHover = isHovered
        guard playbackController.currentItem == nil, presentation.lingeringItem != nil else { return }

        if isHovered {
            lingerCountdown.pause(at: ProcessInfo.processInfo.systemUptime)
            lingerTask?.cancel()
            lingerTask = nil
            cancelFade(restoreOpacity: true)
        } else {
            scheduleLingerDismissal()
        }
    }

    private func hide() {
        guard activeItemID != nil || panel.isVisible else { return }
        cancelLingerDismissal(resetCountdown: true, restoreOpacity: false)
        activeItemID = nil
        lastCurrentItem = nil
        lastDuration = 0
        sessionOpener.clear()
        panel.orderOut(nil)
        panel.alphaValue = 1
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
        lingerCountdown.start(at: ProcessInfo.processInfo.systemUptime)
        if presentation.isHovered {
            lingerCountdown.pause(at: ProcessInfo.processInfo.systemUptime)
        } else {
            scheduleLingerDismissal()
        }
    }

    private func scheduleLingerDismissal() {
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
            guard self.playbackController.currentItem == nil else { return }
            self.lingerCountdown.pause(at: ProcessInfo.processInfo.systemUptime)
            self.beginFadeOut()
        }
    }

    private func beginFadeOut() {
        guard !presentation.isHovered,
              playbackController.currentItem == nil,
              presentation.lingeringItem != nil else { return }
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
            guard !Task.isCancelled, let self, self.isFading else { return }
            guard self.playbackController.currentItem == nil,
                  !self.presentation.isHovered else { return }
            self.hide()
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
            self.geometrySaveTask = nil
            self.preferencesStore.setOrigin(self.panel.frame.origin)
            if self.presentation.isExpanded {
                self.preferencesStore.setExpandedSize(self.panel.frame.size)
            }
        }
    }
}

extension NowSpeakingPanelController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.historySearchItemIdentifier, Self.historyFilterItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.historySearchItemIdentifier, Self.historyFilterItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PlayerResizeRegions: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerResizeRegionsView {
        PlayerResizeRegionsView()
    }

    func updateNSView(_ nsView: PlayerResizeRegionsView, context: Context) {}
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        initialFrame = window?.frame
        initialPointer = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
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

    override func mouseUp(with event: NSEvent) {
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
            self.hoverExitTask = nil
            self.isHovered = false
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
}

private struct NowSpeakingHUDView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: NowSpeakingPresentation
    @ObservedObject var sessionOpener: AgentSessionOpener
    let isWindowedMode: Bool
    let onToggleMiniPlayer: () -> Void
    let onHide: () -> Void

    var body: some View {
        if let item = displayedItem {
            let accent = WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
            VStack(alignment: .leading, spacing: presentation.isExpanded ? 12 : 8) {
                summary(item: item, accent: accent)

                if presentation.isExpanded {
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
                } else {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .controlSize(.mini)
                        .accessibilityLabel("Playback progress")
                }
            }
            .padding(.horizontal, presentation.isExpanded ? 18 : 14)
            .padding(.vertical, presentation.isExpanded ? 16 : 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(PlayerSurfaceStyle(isWindowedMode: isWindowedMode, accent: accent))
            .onHover { presentation.updateHover($0) }
            .animation(.easeInOut(duration: 0.2), value: presentation.isExpanded)
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
            .accessibilityLabel("Now speaking. \(item.nowSpeakingTitle). \(item.nowSpeakingContext)")
        } else if isWindowedMode {
            PlayerHistoryView(controller: controller, presentation: presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
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

            Button(action: isWindowedMode ? stopPlayback : onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: presentation.isExpanded ? 14 : 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(isWindowedMode ? "Stop" : "Hide player")
            .accessibilityLabel(isWindowedMode ? "Stop" : "Hide player")
        }
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
                       item.attachmentID == attachment.id {
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
               let source = presentation.selectedAttachmentText ?? attachment.text {
                MermaidDiagramView(
                    source: source,
                    accentHue: WorkspaceAccent.paletteIndex(forWorkspacePath: item.workspacePath)
                )
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if attachment.kind == .image,
               let image = presentation.selectedAttachmentImage {
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
        case .narratedText: return attachment.isPlayable ? "waveform" : "doc.text"
        case .image: return "photo"
        case .diagram: return "flowchart"
        case .audio: return "speaker.wave.2"
        case .file: return "paperclip"
        }
    }

    private func attachmentHelp(_ attachment: TTSAttachment) -> String {
        switch (attachment.kind, attachment.status) {
        case (_, .failed): return attachment.error ?? "Attachment preparation failed"
        case (.narratedText, .preparing): return "Read while narration is prepared"
        case (.narratedText, .ready), (.audio, .ready): return "Play \(attachment.label)"
        case (.image, _), (.diagram, _): return "Preview \(attachment.label)"
        case (.file, _): return "Open \(attachment.label)"
        case (.audio, .preparing): return "Preparing audio"
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
                        if isLingering {
                            presentation.lingeringTime = newValue
                        } else {
                            controller.seek(to: newValue)
                        }
                    }
                ),
                in: 0...max(playbackDuration, 1),
                onEditingChanged: { isEditing in
                    guard !isEditing, isLingering, let item = presentation.lingeringItem else { return }
                    controller.replay(item, startingAt: presentation.lingeringTime)
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
        HStack(spacing: 12) {
            playbackRateButton(item: item, accent: accent)
            controlButton(symbol: "gobackward.15", label: "Back 15 seconds", accent: accent) {
                if let item = presentation.lingeringItem {
                    controller.replay(item, startingAt: max(0, presentation.lingeringTime - 15))
                } else {
                    controller.rewind()
                }
            }
            controlButton(
                symbol: isLingering ? "arrow.counterclockwise" : (controller.isPaused ? "play.fill" : "pause.fill"),
                label: isLingering ? "Replay" : (controller.isPaused ? "Resume" : "Pause"),
                accent: accent,
                prominent: true
            ) {
                if let item = presentation.lingeringItem {
                    controller.replay(item, startingAt: 0)
                } else {
                    controller.togglePause()
                }
            }
            controlButton(symbol: "stop.fill", label: "Stop", accent: accent) {
                if isLingering {
                    presentation.lingeringItem = nil
                } else {
                    controller.stop()
                }
            }
            controlButton(symbol: "goforward.15", label: "Forward 15 seconds", accent: accent) {
                if let item = presentation.lingeringItem {
                    controller.replay(
                        item,
                        startingAt: min(playbackDuration, presentation.lingeringTime + 15)
                    )
                } else {
                    controller.forward()
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        controller.currentItem ?? presentation.lingeringItem
    }

    private var isLingering: Bool {
        controller.currentItem == nil && presentation.lingeringItem != nil
    }

    private var playbackTime: TimeInterval {
        isLingering ? presentation.lingeringTime : controller.currentTime
    }

    private var playbackDuration: TimeInterval {
        isLingering ? presentation.lingeringDuration : controller.duration
    }

    private var statusSymbol: String {
        if isLingering { return "arrow.counterclockwise" }
        return controller.isPaused ? "pause.fill" : "waveform"
    }

    private func seek(item: TTSItem, to time: TimeInterval) {
        if isLingering {
            controller.replay(item, startingAt: time)
        } else {
            controller.seek(to: time)
        }
    }

    private func stopPlayback() {
        if isLingering {
            presentation.lingeringItem = nil
        } else {
            controller.stop()
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
                        action: { controller.playNow(item) },
                        onRetry: { controller.retryGeneration(item) },
                        isRetrying: controller.isRetrying(item),
                        onArchive: { controller.setArchived(!item.archived, for: item) }
                    )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct PlayerHistoryRow: View {
    let item: TTSItem
    let action: () -> Void
    let onRetry: () -> Void
    let isRetrying: Bool
    let onArchive: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.nowSpeakingTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.status == .generating ? .secondary : .primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let workspace = item.workspaceName {
                            Circle()
                                .fill(WorkspaceAccent.color(forWorkspacePath: item.workspacePath))
                                .frame(width: 6, height: 6)
                            Text(workspace)
                                .fontWeight(.semibold)
                                .foregroundStyle(WorkspaceAccent.color(forWorkspacePath: item.workspacePath))
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                }

                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.status == .generating || item.status == .failed || !FileManager.default.fileExists(atPath: item.outputFile))
            .opacity(item.status == .generating ? 0.62 : 1)
            .help(item.status == .generating ? "Generating audio" : "Play now")
            .accessibilityLabel(accessibilityLabel)

            if item.status == .generating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Generating audio")
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(item.timestampLabel())
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
        .padding(.vertical, 2)
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

    private var accessibilityLabel: String {
        let title = item.subjectLabel ?? item.text
        if item.status == .generating { return "Generating audio for \(title)" }
        if item.status == .failed { return "Failed synthesis for \(title)" }
        return "Play now \(title)"
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
