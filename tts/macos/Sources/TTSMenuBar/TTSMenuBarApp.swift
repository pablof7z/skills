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
    let controller = PlaybackController()
    private let store = QueueStore()
    private lazy var instanceLock = MenuInstanceLock(store: store)
    private let popover = NSPopover()
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
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllerObservation?.cancel()
        controller.shutdown()
        releaseInstanceLock()
        ProcessInfo.processInfo.enableAutomaticTermination("TTS menu bar stays resident")
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem?.button else { return }
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
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeading
        button.title = " TTS"
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 430, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: QueueView(
                controller: controller,
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

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let accessibilityLabel: String
        if controller.isPaused {
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
        button.setAccessibilityLabel(accessibilityLabel)
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
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let current = controller.currentItem {
                CurrentPlaybackView(item: current, controller: controller)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
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
        if controller.isPaused { return "Paused" }
        if controller.currentItem != nil { return "Playing" }
        return controller.queuedItems.isEmpty ? "Idle" : "Waiting"
    }
}

private struct CurrentPlaybackView: View {
    let item: TTSItem
    @ObservedObject var controller: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(controller.isPaused ? "Paused" : "Playing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(controller.isPaused ? .orange : .green)
            }

            TranscriptView(
                text: item.text,
                currentTime: controller.currentTime,
                duration: controller.duration
            )
            .layoutPriority(1)

            CurrentContextView(item: item)

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 1)
            )
            .controlSize(.large)

            HStack {
                Text(time(controller.currentTime))
                Spacer()
                Text("-" + time(max(0, controller.duration - controller.currentTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            TransportControls(controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .playerGlassSurface()
    }

    private func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TransportControls: View {
    @ObservedObject var controller: PlaybackController

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                glassControls
            }
        } else {
            fallbackControls
        }
    }

    @available(macOS 26.0, *)
    private var glassControls: some View {
        HStack(spacing: 22) {
            rewindButton
                .buttonStyle(.glass)
            playPauseButton
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
            forwardButton
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
    }

    private var fallbackControls: some View {
        HStack(spacing: 22) {
            rewindButton
                .buttonStyle(.plain)
                .background(Color.secondary.opacity(0.14), in: Circle())
            playPauseButton
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Circle())
            forwardButton
                .buttonStyle(.plain)
                .background(Color.secondary.opacity(0.14), in: Circle())
        }
        .frame(maxWidth: .infinity)
    }

    private var rewindButton: some View {
        Button {
            controller.rewind()
        } label: {
            Image(systemName: "gobackward.15")
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .help("Rewind 15 seconds")
    }

    private var playPauseButton: some View {
        Button {
            controller.togglePause()
        } label: {
            Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 24, weight: .bold))
                .frame(width: 54, height: 54)
        }
        .keyboardShortcut(.space, modifiers: [])
        .help(controller.isPaused ? "Resume" : "Pause")
    }

    private var forwardButton: some View {
        Button {
            controller.forward()
        } label: {
            Image(systemName: "goforward.15")
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .help("Forward 15 seconds")
    }
}

private struct TranscriptView: View {
    let text: String
    let currentTime: TimeInterval
    let duration: TimeInterval

    var body: some View {
        ScrollView {
            transcript
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Transcript")
    }

    private var transcript: Text {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return Text("") }

        let progress = duration > 0 ? min(max(currentTime / duration, 0), 0.999_999) : 0
        let activeIndex = min(Int(progress * Double(words.count)), words.count - 1)

        return words.enumerated().reduce(Text("")) { result, entry in
            let (index, word) = entry
            let token = (index == 0 ? "" : " ") + word
            let styled: Text
            if index < activeIndex {
                styled = Text(token).foregroundColor(.primary)
            } else if index == activeIndex {
                styled = Text(token)
                    .foregroundColor(.accentColor)
                    .fontWeight(.bold)
                    .underline()
            } else {
                styled = Text(token).foregroundColor(.secondary.opacity(0.62))
            }
            return result + styled
        }
    }
}

private extension View {
    @ViewBuilder
    func playerGlassSurface() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(Color.accentColor.opacity(0.08)),
                in: .rect(cornerRadius: 8)
            )
        } else {
            background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct CurrentContextView: View {
    let item: TTSItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MetadataLine(item: item)

            if let session = item.sessionLabel {
                HStack(spacing: 5) {
                    Text("Session")
                        .foregroundStyle(.tertiary)
                    Text(session)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .help(session)
            }

            Text(contextLine)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
    }

    private var contextLine: String {
        var details: [String] = []
        if let harness = item.harness, !harness.isEmpty {
            details.append("Harness " + harness)
        }
        if let workspace = item.workspaceName {
            details.append("Workspace " + workspace)
        }
        return details.joined(separator: " · ")
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
                .accessibilityLabel("Replay " + item.text)
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
                Text(item.text)
                    .lineLimit(2)
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
