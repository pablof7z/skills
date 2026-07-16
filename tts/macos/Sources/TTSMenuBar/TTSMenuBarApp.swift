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
    private lazy var askNotificationCenter = AskNotificationCenter()
    private lazy var askAttentionController = AskAttentionController(
        playbackController: controller,
        preferencesStore: playerPreferencesStore,
        authorizeNotifications: { [weak askNotificationCenter] in
            askNotificationCenter?.requestAuthorization()
        },
        deliverNotification: { [weak askNotificationCenter] item in
            askNotificationCenter?.deliver(for: item)
        }
    )
    private lazy var windowPreferencesStore = PlayerWindowPreferencesStore(stateDirectory: store.stateDirectory)
    private lazy var instanceLock = MenuInstanceLock(store: store)
    private lazy var playerWindowController = NowSpeakingPanelController(
        controller: controller,
        preferencesStore: windowPreferencesStore,
        playerPreferencesStore: playerPreferencesStore
    )
    private lazy var preferencesWindowController = PlayerPreferencesWindowController(
        preferencesStore: playerPreferencesStore
    )
    private lazy var endpointMonitor = RemoteEndpointMonitor(
        reader: RemoteEndpointStateReader(stateDirectory: store.stateDirectory)
    )
    private lazy var remotePairingService = RemotePairingService(
        stateDirectory: store.stateDirectory,
        commandRunner: ShellTTSRemoteCommandRunner()
    )
    private lazy var pairingWindowController = RemotePairingWindowController(
        service: remotePairingService,
        didCreateOffer: { [weak endpointMonitor] in endpointMonitor?.refresh() }
    )
    private lazy var menuBarController = MenuBarController(
        playbackController: controller,
        preferencesStore: playerPreferencesStore,
        endpointMonitor: endpointMonitor,
        showPlayer: { [weak playerWindowController] in playerWindowController?.showPlayer() },
        showPairing: { [weak pairingWindowController] in pairingWindowController?.show() },
        showPreferences: { [weak preferencesWindowController] in preferencesWindowController?.show() }
    )
    private var ownsLock = false

    func applicationDidFinishLaunching(_: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("TTS stays available in the background")
        NSApp.setActivationPolicy(.regular)
        guard acquireInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        configureMainMenu()
        menuBarController.start()
        playerWindowController.refresh()
        controller.start()
        askAttentionController.start()
        ensureRemoteListenerRunning()
    }

    func applicationWillTerminate(_: Notification) {
        menuBarController.stop()
        askAttentionController.stop()
        playerWindowController.shutdown()
        controller.shutdown()
        releaseInstanceLock()
        ProcessInfo.processInfo.enableAutomaticTermination("TTS stays available in the background")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            playerWindowController.showPlayer()
        }
        return true
    }

    private func ensureRemoteListenerRunning() {
        let service = remotePairingService
        Task.detached(priority: .utility) {
            try? service.ensureListenerRunning()
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func applicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "TTS Queue")
        let preferences = NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        preferences.keyEquivalentModifierMask = [.command]
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TTS Queue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        let showPlayer = NSMenuItem(title: "Show Player", action: #selector(showPlayer), keyEquivalent: "0")
        showPlayer.keyEquivalentModifierMask = [.command]
        showPlayer.target = self
        menu.addItem(showPlayer)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func showPlayer() {
        playerWindowController.showPlayer()
    }

    @objc private func showPreferences() {
        preferencesWindowController.show()
    }

    private func acquireInstanceLock() -> Bool {
        do {
            ownsLock = try instanceLock.acquire()
            return ownsLock
        } catch {
            NSLog("Unable to acquire TTS app lock: %@", error.localizedDescription)
            return false
        }
    }

    private func releaseInstanceLock() {
        guard ownsLock else { return }
        instanceLock.release()
        ownsLock = false
    }
}
