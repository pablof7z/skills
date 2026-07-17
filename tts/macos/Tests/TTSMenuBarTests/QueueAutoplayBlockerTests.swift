import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct QueueAutoplayBlockerTests {
    @Test
    func reportsEveryActiveBlockerInStablePriorityOrder() {
        let blockers = QueueAutoplayBlockerPolicy.blockers(
            isGloballyPaused: true,
            isSystemOutputMuted: true,
            visibleAskQueueHoldID: "ask"
        )

        #expect(blockers == [.globalPause, .systemOutputMuted, .visibleAsk])
        #expect(
            QueueAutoplayBlockerPolicy.summary(blockers)
                == "Global pause, Output muted, Ask awaiting answer"
        )
    }

    @Test
    func reportsNoBlockerWhenAutoplayCanAdvance() {
        #expect(
            QueueAutoplayBlockerPolicy.blockers(
                isGloballyPaused: false,
                isSystemOutputMuted: false,
                visibleAskQueueHoldID: nil
            ).isEmpty
        )
    }

    @Test
    func playbackControllerIncludesTheVisibleAskHold() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PlaybackController(
            store: QueueStore(stateDirectory: directory),
            outputIsMuted: { false }
        )

        controller.visibleAskQueueHoldID = "ask"

        #expect(controller.queueAutoplayBlockers == [.visibleAsk])
    }

    @Test
    func menuBarStateNamesAllBlockers() {
        let state = MenuBarPresentation.playbackState(
            blockers: [.globalPause, .systemOutputMuted, .visibleAsk],
            hasCurrentItem: true,
            isGenerating: true
        )

        #expect(state.symbol == "pause.circle.fill")
        #expect(
            state.label
                == "Autoplay blocked: Global pause, Output muted, Ask awaiting answer"
        )
    }

    @Test
    func visibleAskUsesAQuestionIndicatorInTheMenuBar() {
        let state = MenuBarPresentation.playbackState(
            blockers: [.visibleAsk],
            hasCurrentItem: false,
            isGenerating: false
        )

        #expect(state == MenuBarPlaybackState(
            symbol: "questionmark.bubble.fill",
            label: "Autoplay blocked: Ask awaiting answer"
        ))
    }

    @Test
    func keepsNormalMenuBarStatesWhenAutoplayIsUnblocked() {
        #expect(MenuBarPresentation.playbackState(
            blockers: [],
            hasCurrentItem: true,
            isGenerating: true
        ) == MenuBarPlaybackState(symbol: "waveform.circle.fill", label: "TTS playing"))
        #expect(MenuBarPresentation.playbackState(
            blockers: [],
            hasCurrentItem: false,
            isGenerating: true
        ) == MenuBarPlaybackState(symbol: "ellipsis.circle", label: "TTS generating"))
        #expect(MenuBarPresentation.playbackState(
            blockers: [],
            hasCurrentItem: false,
            isGenerating: false
        ) == MenuBarPlaybackState(symbol: "speaker.wave.2", label: "TTS idle"))
    }
}
