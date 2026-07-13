import AppKit
import Combine
import SwiftUI

@MainActor
final class NowSpeakingPanelController {
    private enum Layout {
        static let prominentSize = NSSize(width: 380, height: 112)
        static let quietSize = NSSize(width: 320, height: 76)
        static let screenInset: CGFloat = 20
        static let prominentSeconds: UInt64 = 5
    }

    private let playbackController: PlaybackController
    private let presentation = NowSpeakingPresentation()
    private let panel: PassiveHUDPanel
    private var playbackObservation: AnyCancellable?
    private var screenObservation: AnyCancellable?
    private var collapseTask: Task<Void, Never>?
    private var activeItemID: String?

    init(controller: PlaybackController) {
        playbackController = controller
        panel = PassiveHUDPanel(
            contentRect: NSRect(origin: .zero, size: Layout.prominentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        panel.contentViewController = NSHostingController(
            rootView: NowSpeakingHUDView(
                controller: controller,
                presentation: presentation
            )
        )

        playbackObservation = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        screenObservation = NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.positionPanel(size: self?.panel.frame.size ?? Layout.prominentSize)
            }
        }
    }

    func refresh() {
        guard let item = playbackController.currentItem else {
            hide()
            return
        }

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
        screenObservation?.cancel()
        collapseTask?.cancel()
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
        panel.ignoresMouseEvents = true
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
        presentation.isProminent = true
        positionPanel(size: Layout.prominentSize)
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
            self.collapse()
        }
    }

    private func collapse() {
        presentation.isProminent = false
        let frame = frameFor(size: Layout.quietSize)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 0.78
        }
    }

    private func hide() {
        guard activeItemID != nil || panel.isVisible else { return }
        collapseTask?.cancel()
        collapseTask = nil
        activeItemID = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
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

@MainActor
private final class NowSpeakingPresentation: ObservableObject {
    @Published var isProminent = true
}

private struct NowSpeakingHUDView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: NowSpeakingPresentation

    var body: some View {
        if let item = controller.currentItem {
            VStack(alignment: .leading, spacing: presentation.isProminent ? 10 : 7) {
                HStack(alignment: .center, spacing: presentation.isProminent ? 12 : 9) {
                    Image(systemName: controller.isPaused ? "pause.fill" : "waveform")
                        .font(.system(
                            size: presentation.isProminent ? 18 : 14,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tint)
                        .frame(
                            width: presentation.isProminent ? 34 : 26,
                            height: presentation.isProminent ? 34 : 26
                        )
                        .background(Color.accentColor.opacity(0.13), in: Circle())

                    VStack(alignment: .leading, spacing: presentation.isProminent ? 4 : 2) {
                        Text(item.nowSpeakingTitle)
                            .font(presentation.isProminent ? .headline : .subheadline.weight(.semibold))
                            .lineLimit(presentation.isProminent ? 2 : 1)

                        Text(item.nowSpeakingContext)
                            .font(presentation.isProminent ? .caption : .caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .controlSize(.mini)
                    .accessibilityLabel("Playback progress")
            }
            .padding(.horizontal, presentation.isProminent ? 16 : 13)
            .padding(.vertical, presentation.isProminent ? 14 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 18, y: 7)
            .padding(8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now speaking. \(item.nowSpeakingTitle). \(item.nowSpeakingContext)")
        }
    }

    private var progress: Double {
        guard controller.duration > 0 else { return 0 }
        return min(max(controller.currentTime / controller.duration, 0), 1)
    }
}
