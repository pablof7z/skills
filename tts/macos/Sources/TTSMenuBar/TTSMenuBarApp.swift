import AppKit
import Combine
import SwiftUI

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
    private lazy var controller = PlaybackController(store: store)
    private lazy var hudPreferencesStore = HUDPreferencesStore(stateDirectory: store.stateDirectory)
    private lazy var instanceLock = MenuInstanceLock(store: store)
    private let popover = NSPopover()
    private lazy var nowSpeakingPanel = NowSpeakingPanelController(
        controller: controller,
        preferencesStore: hudPreferencesStore
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
        guard let button = statusItem?.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            if popover.isShown {
                popover.performClose(nil)
            }
            showQuickMenu(for: event, button: button)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
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

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 430, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: QueueView(
                controller: controller,
                playerController: nowSpeakingPanel,
                onClose: { [weak self] in self?.popover.performClose(nil) }
            )
        )

        controllerObservation = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }
        updateStatusItem()
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

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc
    private func togglePlayerFromQuickMenu() {
        nowSpeakingPanel.togglePlayerVisibility()
    }

    @objc
    private func toggleGlobalPlaybackFromQuickMenu() {
        controller.toggleGlobalPlaybackPause()
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

private struct QueueView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var playerController: NowSpeakingPanelController
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                if let current = controller.currentItem {
                    Section(controller.isPaused ? "Paused" : "Now Playing") {
                        ItemRow(item: current, action: nil)
                    }
                }

                Section("Up Next") {
                    if controller.queuedItems.isEmpty {
                        Text("Queue is empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.queuedItems) { item in
                            ItemRow(item: item, action: nil)
                        }
                    }
                }

                Section("Recent") {
                    if controller.recentItems.isEmpty {
                        Text("No recent speech")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.recentItems.prefix(30)) { item in
                            ItemRow(item: item) {
                                controller.replay(item)
                            }
                            .contextMenu {
                                Button("Replay", systemImage: "arrow.counterclockwise") {
                                    controller.replay(item)
                                }
                                Button("Show in Finder", systemImage: "folder") {
                                    controller.reveal(item)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
        .frame(width: 430, height: 640)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TTS Queue")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                playerController.togglePlayerVisibility()
            } label: {
                Label(
                    playerController.isPlayerVisible ? "Hide Player" : "Show Player",
                    systemImage: playerController.isPlayerVisible ? "eye.slash" : "eye"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(playerController.isPlayerVisible ? "Hide the floating player" : "Show the floating player")
            Button {
                controller.toggleGlobalPlaybackPause()
            } label: {
                Label(
                    controller.isGloballyPaused ? "Resume All" : "Pause All",
                    systemImage: controller.isGloballyPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(controller.isGloballyPaused ? "Resume all TTS playback" : "Pause all TTS playback")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("\(controller.queuedItems.count) queued")
            Spacer()
            Text("\(controller.recentItems.count) recent")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        if controller.isGloballyPaused { return "All playback paused" }
        if controller.isSystemOutputMuted { return "System output muted · playback waiting" }
        if controller.isPaused { return "Paused" }
        if controller.currentItem != nil { return "Playing" }
        return controller.queuedItems.isEmpty ? "Idle" : "Waiting"
    }
}

private struct ItemRow: View {
    let item: TTSItem
    let action: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent(showsReplay: true)
                }
                .buttonStyle(.plain)
                .disabled(!FileManager.default.fileExists(atPath: item.outputFile))
                .help("Replay")
                .accessibilityLabel("Replay " + (item.subjectLabel ?? item.text))
            } else {
                rowContent(showsReplay: false)
            }
        }
        .padding(.horizontal, 4)
        .background(
            isHovered && action != nil ? Color.accentColor.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovered = $0 }
    }

    private func rowContent(showsReplay: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let subject = item.subjectLabel {
                    Text(subject)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(item.text)
                        .lineLimit(2)
                }
                MetadataLine(item: item)

                if let session = item.sessionLabel {
                    Text("Session " + session)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .help(session)
                }

                Text(contextLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsReplay {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var contextLine: String {
        var details: [String] = []
        if let harness = item.harness, !harness.isEmpty {
            details.append(harness)
        }
        if let workspace = item.workspaceName {
            details.append(workspace)
        }
        if let worktree = item.workspaceWorktreeLabel {
            details.append(worktree)
        }
        details.append(item.createdDate.formatted(date: .omitted, time: .shortened))
        return details.joined(separator: " · ")
    }
}

private struct MetadataLine: View {
    let item: TTSItem

    var body: some View {
        HStack(spacing: 5) {
            Text(item.displayAgent)
                .fontWeight(.medium)
            Text("·")
            Text(item.voice)
            if item.status == .failed {
                Text("· Failed")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
