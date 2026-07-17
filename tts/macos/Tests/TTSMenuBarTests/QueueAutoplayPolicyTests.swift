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
