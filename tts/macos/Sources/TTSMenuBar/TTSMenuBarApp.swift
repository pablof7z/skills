import AppKit
import Combine

@main
struct TTSMenuBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = QueueStore()
    private lazy var playerPreferencesStore = PlayerPreferencesStore(stateDirectory: store.stateDirectory)
    private lazy var mediaController = MediaController(preferencesStore: playerPreferencesStore)
    private lazy var controller = PlaybackController(store: store, mediaController: mediaController)
    private lazy var hudPreferencesStore = HUDPreferencesStore(stateDirectory: store.stateDirectory)
    private lazy var instanceLock = MenuInstanceLock(store: store)
    private lazy var nowSpeakingPanel = NowSpeakingPanelController(
        controller: controller,
        preferencesStore: hudPreferencesStore,
        playerPreferencesStore: playerPreferencesStore
    )
    private lazy var preferencesWindowController = PlayerPreferencesWindowController(
        preferencesStore: playerPreferencesStore
    )
    private var statusItem: NSStatusItem?
    private var controllerObservation: AnyCancellable?
    private var ownsLock = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("TTS menu bar stays resident")
        NSApp.setActivationPolicy(.accessory)
        guard acquireInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        configureStatusItem()
        nowSpeakingPanel.refresh()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllerObservation?.cancel()
        nowSpeakingPanel.shutdown()
        controller.shutdown()
        releaseInstanceLock()
        ProcessInfo.processInfo.enableAutomaticTermination("TTS menu bar stays resident")
    }

    @objc
    private func handleStatusItemClick() {
        guard let button = statusItem?.button, let event = NSApp.currentEvent else { return }
        showQuickMenu(for: event, button: button)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.title = " TTS"
        statusItem = item

        controllerObservation = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }
        updateStatusItem()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "TTS")
        appMenuItem.submenu = appMenu
        let preferencesItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        preferencesItem.keyEquivalentModifierMask = [.command]
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        NSApp.mainMenu = mainMenu
    }

    private func showQuickMenu(for event: NSEvent, button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let playerItem = NSMenuItem(
            title: nowSpeakingPanel.isPlayerVisible ? "Hide Player" : "Show Player",
            action: #selector(togglePlayerFromQuickMenu),
            keyEquivalent: ""
        )
        playerItem.image = NSImage(
            systemSymbolName: nowSpeakingPanel.isPlayerVisible ? "eye.slash" : "eye",
            accessibilityDescription: nil
        )
        playerItem.target = self
        menu.addItem(playerItem)

        let windowedItem = NSMenuItem(
            title: nowSpeakingPanel.isWindowedMode ? "Use Floating HUD" : "Use Windowed Player",
            action: #selector(toggleWindowedModeFromQuickMenu),
            keyEquivalent: ""
        )
        windowedItem.image = NSImage(
            systemSymbolName: nowSpeakingPanel.isWindowedMode ? "pip" : "macwindow",
            accessibilityDescription: nil
        )
        windowedItem.target = self
        menu.addItem(windowedItem)

        let pauseItem = NSMenuItem(
            title: controller.isGloballyPaused ? "Resume All TTS" : "Pause All TTS",
            action: #selector(toggleGlobalPlaybackFromQuickMenu),
            keyEquivalent: ""
        )
        pauseItem.image = NSImage(
            systemSymbolName: controller.isGloballyPaused ? "play.fill" : "pause.fill",
            accessibilityDescription: nil
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        let preferencesItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        preferencesItem.keyEquivalentModifierMask = [.command]
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc
    private func togglePlayerFromQuickMenu() {
        nowSpeakingPanel.togglePlayerVisibility()
    }

    @objc
    private func toggleWindowedModeFromQuickMenu() {
        nowSpeakingPanel.toggleWindowedMode()
    }

    @objc
    private func toggleGlobalPlaybackFromQuickMenu() {
        controller.toggleGlobalPlaybackPause()
    }

    @objc
    private func showPreferences() {
        preferencesWindowController.show()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let accessibilityLabel: String
        if controller.isGloballyPaused {
            symbolName = "pause.circle.fill"
            accessibilityLabel = "All TTS paused, \(controller.queuedItems.count) queued"
        } else if controller.isSystemOutputMuted {
            symbolName = "speaker.slash.circle.fill"
            accessibilityLabel = "System output muted, TTS paused, \(controller.queuedItems.count) queued"
        } else if controller.isPaused {
            symbolName = "pause.circle.fill"
            accessibilityLabel = "TTS paused"
        } else if controller.currentItem != nil {
            symbolName = "waveform.circle.fill"
            accessibilityLabel = "TTS playing"
        } else if controller.isGenerating {
            symbolName = "ellipsis.circle"
            accessibilityLabel = "TTS generating"
        } else if !controller.queuedItems.isEmpty {
            symbolName = "text.line.first.and.arrowtriangle.forward"
            accessibilityLabel = "TTS queued"
        } else {
            symbolName = "speaker.wave.2"
            accessibilityLabel = "TTS idle"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.attributedTitle = statusTitle(queuedCount: controller.queuedItems.count)
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func statusTitle(queuedCount: Int) -> NSAttributedString {
        let title = NSMutableAttributedString(string: " TTS")
        guard queuedCount > 0 else { return title }

        title.append(NSAttributedString(string: " "))
        let attachment = NSTextAttachment()
        let image = queueBadgeImage(count: queuedCount)
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -3, width: image.size.width, height: image.size.height)
        title.append(NSAttributedString(attachment: attachment))
        return title
    }

    private func queueBadgeImage(count: Int) -> NSImage {
        let label = count > 99 ? "99+" : String(count)
        let width: CGFloat = count > 9 ? (count > 99 ? 27 : 21) : 17
        let size = NSSize(width: width, height: 17)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8.5, yRadius: 8.5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: (size.width - labelSize.width) / 2, y: (size.height - labelSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func acquireInstanceLock() -> Bool {
        do {
            ownsLock = try instanceLock.acquire()
            return ownsLock
        } catch {
            NSLog("Unable to acquire TTS menu lock: %@", error.localizedDescription)
            return false
        }
    }

    private func releaseInstanceLock() {
        guard ownsLock else { return }
        instanceLock.release()
        ownsLock = false
    }
}
