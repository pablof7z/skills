import AppKit
import Combine
import SwiftUI

@MainActor
final class NowSpeakingPanelController {
    private enum Layout {
        static let compactSize = NSSize(width: 400, height: 120)
        static let playerSize = NSSize(width: 470, height: 226)
        static let transcriptSize = NSSize(width: 540, height: 470)
        static let screenInset: CGFloat = 20
        static let prominentSeconds: UInt64 = 5
        static let lingerSeconds: TimeInterval = 8
        static let fadeSeconds: TimeInterval = 0.34
    }

    private let playbackController: PlaybackController
    private let presentation = NowSpeakingPresentation()
    private let panel: PassiveHUDPanel
    private var playbackObservation: AnyCancellable?
    private var presentationObservation: AnyCancellable?
    private var screenObservation: AnyCancellable?
    private var collapseTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var activeItemID: String?
    private var lastCurrentItem: TTSItem?
    private var lastDuration: TimeInterval = 0
    private var lingerCountdown = LingerCountdown(duration: Layout.lingerSeconds)
    private var observedHover = false
    private var isFading = false

    init(controller: PlaybackController) {
        playbackController = controller
        panel = PassiveHUDPanel(
            contentRect: NSRect(origin: .zero, size: Layout.playerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        let hostingView = FirstMouseHostingView(
            rootView: NowSpeakingHUDView(
                controller: controller,
                presentation: presentation
            )
            .environment(\.colorScheme, .dark)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

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
                self?.positionPanel(size: self?.panel.frame.size ?? Layout.playerSize)
            }
        }
    }

    func refresh() {
        guard let item = playbackController.currentItem else {
            beginLingerIfNeeded()
            return
        }

        if presentation.lingeringItem != nil || lingerTask != nil || isFading {
            cancelLingerDismissal(resetCountdown: true, restoreOpacity: true)
        }
        presentation.lingeringItem = nil
        lastCurrentItem = item
        lastDuration = max(playbackController.duration, item.duration ?? 0)

        if activeItemID != item.id {
            activeItemID = item.id
            showProminently()
            scheduleCollapse(for: item.id)
        } else if !panel.isVisible {
            showProminently()
        }
    }

    func shutdown() {
        playbackObservation?.cancel()
        presentationObservation?.cancel()
        screenObservation?.cancel()
        collapseTask?.cancel()
        lingerTask?.cancel()
        fadeTask?.cancel()
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Now speaking")
    }

    private func showProminently() {
        collapseTask?.cancel()
        presentation.isTranscriptVisible = false
        presentation.isProminent = true
        positionPanel(size: Layout.playerSize)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleCollapse(for itemID: String) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Layout.prominentSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.activeItemID == itemID else { return }
            self.presentation.isProminent = false
        }
    }

    private func updateLayout(animated: Bool) {
        if playbackController.currentItem == nil && presentation.lingeringItem == nil {
            hide()
            return
        }
        guard panel.isVisible else { return }
        let size: NSSize
        if presentation.isTranscriptVisible {
            size = Layout.transcriptSize
        } else if presentation.isExpanded {
            size = Layout.playerSize
        } else {
            size = Layout.compactSize
        }
        let frame = frameFor(size: size)
        let alpha: CGFloat = presentation.isExpanded ? 1 : 0.84

        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }
    }

    private func presentationDidChange() {
        updateLayout(animated: true)

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
        collapseTask?.cancel()
        cancelLingerDismissal(resetCountdown: true, restoreOpacity: false)
        collapseTask = nil
        activeItemID = nil
        lastCurrentItem = nil
        lastDuration = 0
        panel.orderOut(nil)
        panel.alphaValue = 1
        presentation.isHovered = false
        presentation.isTranscriptVisible = false
        presentation.lingeringItem = nil
        presentation.lingeringTime = 0
        presentation.lingeringDuration = 0
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
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(origin: NSPoint(x: Layout.screenInset, y: Layout.screenInset), size: size)
        }
        return NSRect(
            x: visibleFrame.minX + Layout.screenInset,
            y: visibleFrame.minY + Layout.screenInset,
            width: size.width,
            height: size.height
        )
    }
}

final class PassiveHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class NowSpeakingPresentation: ObservableObject {
    @Published var isProminent = true
    @Published var isHovered = false
    @Published var isTranscriptVisible = false
    @Published var lingeringItem: TTSItem?
    @Published var lingeringTime: TimeInterval = 0
    @Published var lingeringDuration: TimeInterval = 0

    var isExpanded: Bool {
        isProminent || isHovered || isTranscriptVisible
    }
}

private struct NowSpeakingHUDView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: NowSpeakingPresentation

    var body: some View {
        if let item = displayedItem {
            let accent = WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
            VStack(alignment: .leading, spacing: presentation.isExpanded ? 12 : 8) {
                summary(item: item, accent: accent)

                if presentation.isExpanded {
                    timeline(accent: accent)
                    controls(accent: accent)
                } else {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .controlSize(.mini)
                        .accessibilityLabel("Playback progress")
                }

                if presentation.isTranscriptVisible {
                    Divider().overlay(Color.white.opacity(0.11))
                    WordTranscriptView(
                        text: item.text,
                        currentTime: playbackTime,
                        duration: playbackDuration,
                        accent: accent,
                        onSeek: { seek(item: item, to: $0) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, presentation.isExpanded ? 18 : 14)
            .padding(.vertical, presentation.isExpanded ? 16 : 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hudSurface(accent: accent)
            .padding(8)
            .onHover { presentation.isHovered = $0 }
            .animation(.easeInOut(duration: 0.2), value: presentation.isTranscriptVisible)
            .accessibilityLabel("Now speaking. \(item.nowSpeakingTitle). \(item.nowSpeakingContext)")
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

            Button {
                presentation.isTranscriptVisible.toggle()
            } label: {
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
                                .truncationMode(.middle)
                        }
                        .font(presentation.isExpanded ? .caption : .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Workspace \(workspaceLabel)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.isTranscriptVisible ? "Collapse transcript" : "Show transcript")

            Button {
                presentation.isTranscriptVisible.toggle()
            } label: {
                Image(systemName: presentation.isTranscriptVisible ? "chevron.down.circle.fill" : "text.bubble")
                    .font(.system(size: presentation.isExpanded ? 20 : 16, weight: .medium))
                    .foregroundStyle(presentation.isTranscriptVisible ? accent : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(presentation.isTranscriptVisible ? "Collapse transcript" : "Show transcript")
            .accessibilityLabel(presentation.isTranscriptVisible ? "Collapse transcript" : "Show transcript")
        }
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

    private func controls(accent: Color) -> some View {
        HStack(spacing: 15) {
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

    private func formattedTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct WordTranscriptView: View {
    let text: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let accent: Color
    let onSeek: (TimeInterval) -> Void
    @State private var hoveredIndex: Int?

    private var words: [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private var activeIndex: Int? {
        TranscriptTiming.activeWordIndex(
            currentTime: currentTime,
            duration: duration,
            wordCount: words.count
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                WordFlowLayout(horizontalSpacing: 4, verticalSpacing: 3) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        let decoration = TranscriptWordDecoration.resolve(
                            isCurrent: index == activeIndex,
                            isHovered: index == hoveredIndex
                        )
                        Button {
                            onSeek(TranscriptTiming.time(
                                forWordAt: index,
                                wordCount: words.count,
                                duration: duration
                            ))
                        } label: {
                            Text(word)
                                .font(.body.weight(index == activeIndex ? .semibold : .regular))
                                .foregroundStyle(wordColor(at: index))
                                .background {
                                    if decoration.accentOpacity > 0 {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(accent.opacity(decoration.accentOpacity))
                                            .padding(.horizontal, -3)
                                            .padding(.vertical, -2)
                                    }
                                }
                                .scaleEffect(decoration.scale)
                                .offset(y: decoration.verticalOffset)
                                .contentShape(Rectangle().inset(by: -2))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            if isHovered {
                                hoveredIndex = index
                                NSCursor.pointingHand.set()
                            } else if hoveredIndex == index {
                                hoveredIndex = nil
                                NSCursor.arrow.set()
                            }
                        }
                        .animation(.easeOut(duration: 0.12), value: decoration)
                        .id(index)
                        .accessibilityLabel("Seek to \(word)")
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                guard let activeIndex else { return }
                proxy.scrollTo(activeIndex, anchor: .center)
            }
            .onChange(of: activeIndex) { newIndex in
                guard let newIndex else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Interactive transcript")
        .onDisappear {
            NSCursor.arrow.set()
        }
    }

    private func wordColor(at index: Int) -> Color {
        guard let activeIndex else { return .secondary }
        if index < activeIndex { return .primary.opacity(0.88) }
        if index == activeIndex { return accent }
        return .secondary.opacity(0.62)
    }
}

private struct WordFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposal.width ?? max(0, x - horizontalSpacing), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
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
