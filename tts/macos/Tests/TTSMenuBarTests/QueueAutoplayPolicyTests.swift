import AVFAudio
import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct QueueAutoplayPolicyTests {
    @Test
    func onlyAVisibleDisplayedPendingAskHoldsTheQueue() {
        var ask = QueueStoreTests().item(id: "ask", createdAt: 10)
        ask.kind = .question
        ask.questionStatus = .pending
        var answered = ask
        answered.questionStatus = .answered
        let speech = QueueStoreTests().item(id: "speech", createdAt: 20)

        #expect(heldItemID(current: ask) == ask.id)
        #expect(heldItemID(preview: ask) == ask.id)
        #expect(heldItemID(lingering: ask) == ask.id)
        #expect(heldItemID(current: answered) == nil)
        #expect(heldItemID(current: ask, hiddenItemID: ask.id) == nil)
        #expect(heldItemID(current: ask, isPlayerVisible: false) == nil)
        #expect(heldItemID(current: ask, isWindowVisible: false) == nil)
        #expect(heldItemID(current: speech, preview: ask) == ask.id)
        #expect(heldItemID() == nil)
    }

    @Test
    func queuedSpeechParksALocallyPausedItemAndResumesItFromHistory() throws {
        let support = QueueStoreTests()
        let directory = support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try support.writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        var paused = support.item(id: "paused", createdAt: 10, outputFile: audio.path)
        paused.status = .paused
        paused.startedAt = 10
        let next = support.item(id: "next", createdAt: 20, outputFile: audio.path)
        try store.save(paused)
        try store.save(next)

        let controller = PlaybackController(
            store: store,
            mediaController: support.disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false }
        )
        defer { controller.shutdown() }
        let audioPlayer = try AVAudioPlayer(contentsOf: audio)
        audioPlayer.currentTime = 0.05
        controller.items = [paused, next]
        controller.currentItemID = paused.id
        controller.player = audioPlayer

        controller.refresh()

        let parked = try #require(try store.item(id: paused.id))
        #expect(parked.status == .interrupted)
        #expect(parked.unheard)
        #expect(abs((parked.playbackOffset ?? 0) - 0.05) < 0.01)
        #expect(controller.currentItem?.id == next.id)

        controller.playNow(parked)

        #expect(controller.currentItem?.id == paused.id)
        #expect(abs(controller.currentTime - 0.05) < 0.01)
    }

    private func heldItemID(
        current: TTSItem? = nil,
        preview: TTSItem? = nil,
        lingering: TTSItem? = nil,
        hiddenItemID: String? = nil,
        isPlayerVisible: Bool = true,
        isWindowVisible: Bool = true
    ) -> String? {
        VisibleAskQueueHoldPolicy.heldItemID(
            isPlayerVisible: isPlayerVisible,
            isWindowVisible: isWindowVisible,
            currentItem: current,
            pendingPreviewItem: preview,
            lingeringItem: lingering,
            hiddenItemID: hiddenItemID
        )
    }

    @Test
    func explicitlyOpenedAskHoldsQueueWhileAnotherItemPlays() {
        var current = policyItem(id: "playing")
        current.status = .playing
        var ask = policyItem(id: "ask")
        ask.kind = .question
        ask.questionStatus = .pending

        #expect(heldItemID(current: current, preview: ask) == ask.id)
    }

    private func policyItem(id: String) -> TTSItem {
        TTSItem(
            id: id,
            text: "Speech",
            agentName: "codex",
            voice: "af_heart",
            outputFile: "/tmp/\(id).mp3",
            status: .queued,
            createdAt: 1
        )
    }
}
