import Testing
@testable import TTSMenuBar

@Suite
struct PlayerQueueMiniPlayerTests {
    @Test
    func playerListKeepsActivePlaybackVisible() {
        #expect(PlayerListPolicy.includes(.playing))
        #expect(PlayerListPolicy.includes(.paused))
        #expect(PlayerListPolicy.includes(.played))
        #expect(!PlayerListPolicy.includes(.queued))
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
}
