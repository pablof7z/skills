import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let playbackController: PlaybackController
    private let preferencesStore: PlayerPreferencesStore
    private let endpointMonitor: RemoteEndpointMonitor
    private let showPlayer: () -> Void
    private let showPairing: () -> Void
    private let showPreferences: () -> Void
    private var statusItem: NSStatusItem?
    private var observations = Set<AnyCancellable>()

    init(
        playbackController: PlaybackController,
        preferencesStore: PlayerPreferencesStore,
        endpointMonitor: RemoteEndpointMonitor,
        showPlayer: @escaping () -> Void,
        showPairing: @escaping () -> Void,
        showPreferences: @escaping () -> Void
    ) {
        self.playbackController = playbackController
        self.preferencesStore = preferencesStore
        self.endpointMonitor = endpointMonitor
        self.showPlayer = showPlayer
        self.showPairing = showPairing
        self.showPreferences = showPreferences
        super.init()
    }

    func start() {
        endpointMonitor.start()
        playbackController.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }.store(in: &observations)
        preferencesStore.$preferences.sink { [weak self] preferences in
            self?.setVisible(preferences.showsMenuBarItem)
        }.store(in: &observations)
        endpointMonitor.$snapshot.sink { [weak self] _ in
            self?.updateStatusItem()
        }.store(in: &observations)
        setVisible(preferencesStore.preferences.showsMenuBarItem)
    }

    func stop() {
        observations.removeAll()
        endpointMonitor.stop()
        removeStatusItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            createStatusItem()
        } else if !visible {
            removeStatusItem()
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(title: "TTS")
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem()
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let count = MenuBarPresentation.badgeCount(in: playbackController.items)
        let state = playbackState
        button.image = NSImage(
            systemSymbolName: state.symbol,
            accessibilityDescription: state.label
        )
        button.attributedTitle = badgeTitle(count: count)
        button.toolTip = state.label
        button.setAccessibilityLabel(count > 0 ? "\(state.label), \(count) unplayed" : state.label)
    }

    private var playbackState: MenuBarPlaybackState {
        MenuBarPresentation.playbackState(
            blockers: playbackController.queueAutoplayBlockers,
            hasCurrentItem: playbackController.currentItem != nil,
            isGenerating: playbackController.isGenerating
        )
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let blockers = playbackController.queueAutoplayBlockers
        if !blockers.isEmpty {
            menu.addItem(disabledItem("Queue autoplay is blocked", symbol: "exclamationmark.triangle.fill"))
            for blocker in blockers {
                menu.addItem(disabledItem("  \(blocker.shortLabel) — \(blocker.detail)", symbol: blocker.symbol))
            }
            menu.addItem(.separator())
        }
        let endpoint = endpointMonitor.snapshot
        menu.addItem(disabledItem(
            endpoint.isListening ? "Remote listener connected" : "Remote listener stopped",
            symbol: endpoint.isListening ? "circle.fill" : "circle"
        ))
        if endpoint.backends.isEmpty {
            menu.addItem(disabledItem("No paired remote computers", symbol: "laptopcomputer"))
        } else {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Paired remote computers", symbol: nil))
            for backend in endpoint.backends {
                let suffix = backend.relay.map { " — \($0)" } ?? ""
                menu.addItem(disabledItem("  \(backend.displayName)\(suffix)", symbol: "server.rack"))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Show Player", symbol: "rectangle.stack", action: #selector(showPlayerAction)))
        menu.addItem(actionItem("Pair New Computer…", symbol: "plus.circle", action: #selector(showPairingAction)))
        menu.addItem(actionItem("Settings…", symbol: "gearshape", action: #selector(showPreferencesAction)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit TTS Queue", symbol: nil, action: #selector(quit)))
    }

    private func disabledItem(_ title: String, symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        return item
    }

    private func actionItem(_ title: String, symbol: String?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        return item
    }

    @objc private func showPlayerAction() { showPlayer() }
    @objc private func showPairingAction() { showPairing() }
    @objc private func showPreferencesAction() { showPreferences() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func badgeTitle(count: Int) -> NSAttributedString {
        guard count > 0 else { return NSAttributedString(string: "") }
        let attachment = NSTextAttachment()
        let image = badgeImage(count: count)
        attachment.image = image
        attachment.bounds = NSRect(x: 2, y: -3, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func badgeImage(count: Int) -> NSImage {
        let label = count > 99 ? "99+" : String(count)
        let size = NSSize(width: count > 99 ? 27 : count > 9 ? 21 : 17, height: 17)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8.5, yRadius: 8.5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
