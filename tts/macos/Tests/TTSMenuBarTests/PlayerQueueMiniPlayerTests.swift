import Testing
@testable import TTSMenuBar

@Suite
struct PlayerQueueMiniPlayerTests {
    @Test @MainActor
    func selectingAnOrdinaryRowClearsAnEarlierPreview() {
        let presentation = NowSpeakingPresentation()
        presentation.previewPendingItem(item(id: "ask", status: .played))

        presentation.revealForDirectSelection(itemID: "ordinary")

        #expect(presentation.pendingPreviewItem == nil)
    }

    @Test
    func explicitlyOpenedPendingItemTakesPriorityOverPlayback() {
        let current = item(id: "playing", status: .playing)
        let preview = item(id: "ask", status: .played)
        let lingering = item(id: "finished", status: .played)

        #expect(PlayerContentSelection.displayedItem(
            currentItem: current,
            pendingPreviewItem: preview,
            lingeringItem: lingering
        )?.id == preview.id)
    }

    @Test
    func activePlaybackStateRequiresMatchingPlayingOrPausedItem() {
        #expect(PlayerHistoryPlaybackState(
            itemID: "playing",
            currentItemID: "playing",
            status: .playing
        ) == .playing)
        #expect(PlayerHistoryPlaybackState(
            itemID: "paused",
            currentItemID: "paused",
            status: .paused
        ) == .paused)
        #expect(PlayerHistoryPlaybackState(
            itemID: "other",
            currentItemID: "playing",
            status: .playing
        ) == nil)
        #expect(PlayerHistoryPlaybackState(
            itemID: "playing",
            currentItemID: "playing",
            status: .played
        ) == nil)
    }

    @Test
    func playerListKeepsActivePlaybackVisible() {
        #expect(PlayerListPolicy.includes(.playing))
        #expect(PlayerListPolicy.includes(.paused))
        #expect(PlayerListPolicy.includes(.played))
        #expect(PlayerListPolicy.includes(.queued))
        #expect(!PlayerListPolicy.includes(.generated))
    }

    @Test
    func playerListExcludesGenerationOnlyItemsAcrossTheirLifecycle() {
        for status in [PlaybackStatus.generating, .generated, .failed] {
            #expect(!PlayerListPolicy.includes(status, playbackRequested: false))
        }
    }

    @Test
    func miniPlayerAppearsOnlyWhenCurrentPlaybackIsHiddenByQueueNavigation() {
        #expect(PlayerNavigationPolicy.shouldShowMiniPlayer(
            currentItemID: "speaking",
            hiddenItemID: "speaking"
        ))
        #expect(!PlayerNavigationPolicy.shouldShowMiniPlayer(
            currentItemID: "speaking",
            hiddenItemID: nil
        ))
        #expect(!PlayerNavigationPolicy.shouldShowMiniPlayer(
            currentItemID: nil,
            hiddenItemID: "speaking"
        ))
        #expect(!PlayerNavigationPolicy.shouldShowMiniPlayer(
            currentItemID: "next",
            hiddenItemID: "speaking"
        ))
    }

    @Test
    func miniPlayerShowsOnlyRemainingPlaybackTime() {
        #expect(QueueMiniPlayerPresentation.remainingTimeLabel(duration: 125, currentTime: 45) == "-1:20")
        #expect(QueueMiniPlayerPresentation.remainingTimeLabel(duration: 45, currentTime: 125) == "-0:00")
    }

    private func item(id: String, status: PlaybackStatus) -> TTSItem {
        TTSItem(
            id: id,
            text: "Speech",
            agentName: "codex",
            voice: "af_heart",
            outputFile: "/tmp/\(id).mp3",
            status: status,
            createdAt: 1
        )
    }
}
