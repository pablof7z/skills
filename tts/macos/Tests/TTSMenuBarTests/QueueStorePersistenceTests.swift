import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TTSMenuBar

struct QueueStoreTests {}

extension QueueStoreTests {
    @Test
    func savesAndLoadsItemsInQueueOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)

        try store.save(item(id: "later", createdAt: 20))
        try store.save(item(id: "earlier", createdAt: 10))

        #expect(try store.loadItems().map(\.id) == ["earlier", "later"])
    }

    @Test
    func itemChangeTokenAdvancesAfterAnAtomicQueueWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)

        let before = try store.itemsChangeToken()
        try store.save(item(id: "new-item", createdAt: 10))
        let after = try store.itemsChangeToken()

        #expect(after > before)
    }

    @Test
    func recoversInterruptedPlayback() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.mp3")
        try Data("audio".utf8).write(to: audio)
        let store = QueueStore(stateDirectory: directory)

        var interrupted = item(id: "active", createdAt: 10, outputFile: audio.path)
        interrupted.status = .paused
        interrupted.startedAt = 11
        try store.save(interrupted)

        try store.recoverInterruptedItems()

        let recovered = try #require(store.loadItems().first)
        #expect(recovered.status == .queued)
        #expect(recovered.startedAt == nil)
    }

    @Test
    func persistsGlobalPlaybackPauseAcrossProcesses() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)

        #expect(!store.isGlobalPlaybackPaused())
        try store.setGlobalPlaybackPaused(true)
        #expect(store.isGlobalPlaybackPaused())
        #expect(FileManager.default.fileExists(atPath: store.globalPlaybackPauseFile.path))

        let reloaded = QueueStore(stateDirectory: directory)
        #expect(reloaded.isGlobalPlaybackPaused())
        try reloaded.setGlobalPlaybackPaused(false)
        #expect(!store.isGlobalPlaybackPaused())
    }

    @Test
    func persistsPlayerVisibilityAndPosition() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayerWindowPreferencesStore(stateDirectory: directory)

        #expect(store.preferences == PlayerWindowPreferences())
        store.setPlayerVisible(false)
        store.setMiniPlayer(true)
        store.setOrigin(CGPoint(x: -820, y: 146))
        store.setExpandedSize(CGSize(width: 680, height: 560))

        let reloaded = PlayerWindowPreferencesStore(stateDirectory: directory)
        #expect(!reloaded.preferences.isPlayerVisible)
        #expect(reloaded.preferences.isMiniPlayer)
        #expect(reloaded.preferences.origin == CGPoint(x: -820, y: 146))
        #expect(reloaded.preferences.expandedSize == CGSize(width: 680, height: 560))
    }

    @Test @MainActor
    func persistsMediaPreferences() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayerPreferencesStore(stateDirectory: directory)

        #expect(store.preferences == PlayerPreferences())
        store.setPausesMedia(true)
        store.setMediaHandoffDelay(1.5)
        store.setMediaResumeDelay(4.5)
        store.setMaxParallelGenerations(6)

        let reloaded = PlayerPreferencesStore(stateDirectory: directory)
        #expect(reloaded.preferences.pausesMedia)
        #expect(reloaded.preferences.mediaHandoffDelay == 1.5)
        #expect(reloaded.preferences.mediaResumeDelay == 4.5)
        #expect(reloaded.preferences.maxParallelGenerations == 6)
    }

    @Test @MainActor
    func legacyMediaControlPreferenceRequiresFreshConsent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = Data(
            #"{"pausesMedia":true,"mediaHandoffDelay":1,"mediaResumeDelay":4}"#.utf8
        )
        try legacy.write(to: directory.appendingPathComponent("player-preferences.json"))

        let migrated = PlayerPreferencesStore(stateDirectory: directory)

        #expect(!migrated.preferences.pausesMedia)
        #expect(migrated.preferences.maxParallelGenerations == 2)
    }

    @Test
    func clampsPlayerGenerationLimitToSafeSettingsRange() {
        #expect(PlayerPreferences(maxParallelGenerations: 0).maxParallelGenerations == 1)
        #expect(PlayerPreferences(maxParallelGenerations: 99).maxParallelGenerations == 8)
    }

    @Test
    func clampsSavedPlayerPositionOntoRemainingDisplay() {
        let frame = HUDPlacement.frame(
            size: CGSize(width: 540, height: 470),
            preferredOrigin: CGPoint(x: 3200, y: 1400),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)],
            inset: 20
        )

        #expect(frame == CGRect(x: 880, y: 410, width: 540, height: 470))
    }

    @Test
    func keepsPlayerOnItsSavedDisplayWhileThatDisplayExists() {
        let frame = HUDPlacement.frame(
            size: CGSize(width: 400, height: 120),
            preferredOrigin: CGPoint(x: -1000, y: 180),
            visibleFrames: [
                CGRect(x: -1440, y: 0, width: 1440, height: 900),
                CGRect(x: 0, y: 0, width: 1920, height: 1080),
            ],
            inset: 20
        )

        #expect(frame.origin == CGPoint(x: -1000, y: 180))
    }

    @Test
    func reducesOversizedPlayerToFitRemainingDisplay() {
        let frame = HUDPlacement.frame(
            size: CGSize(width: 2000, height: 1200),
            preferredOrigin: CGPoint(x: 3000, y: 1400),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)],
            inset: 20
        )

        #expect(frame == CGRect(x: 20, y: 20, width: 1400, height: 860))
    }

    @Test
    func restoresOriginalExpandedSizeAsMinimum() {
        let size = HUDPlacement.preferredExpandedSize(
            saved: CGSize(width: 282, height: 205),
            minimum: CGSize(width: 540, height: 470)
        )

        #expect(size == CGSize(width: 540, height: 470))
        #expect(
            HUDPlacement.preferredExpandedSize(
                saved: CGSize(width: 760, height: 620),
                minimum: CGSize(width: 540, height: 470)
            ) == CGSize(width: 760, height: 620)
        )
    }

    @Test
    func resizesFromEveryEdgeWithoutCrossingMinimumOrScreen() {
        let visibleFrame = CGRect(x: 20, y: 20, width: 1400, height: 860)
        let initial = CGRect(x: 200, y: 160, width: 600, height: 520)
        let minimum = CGSize(width: 540, height: 470)

        #expect(
            HUDResize.frame(
                initialFrame: initial,
                pointerDelta: CGPoint(x: 300, y: 300),
                edges: [.right, .top],
                visibleFrame: visibleFrame,
                minimumSize: minimum
            ) == CGRect(x: 200, y: 160, width: 900, height: 720)
        )
        #expect(
            HUDResize.frame(
                initialFrame: initial,
                pointerDelta: CGPoint(x: 300, y: 300),
                edges: [.left, .bottom],
                visibleFrame: visibleFrame,
                minimumSize: minimum
            ) == CGRect(x: 260, y: 210, width: 540, height: 470)
        )
    }

    @Test @MainActor
    func mutedOutputKeepsPendingSpeechQueued() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        try store.save(item(id: "muted", createdAt: 10))
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }

        controller.start()

        #expect(controller.isSystemOutputMuted)
        #expect(controller.currentItem == nil)
        #expect(try store.loadItems().map(\.status) == [.queued])
    }

    @Test @MainActor
    func generatingSpeechAppearsInPlayerListButNotPlaybackQueue() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var generating = item(id: "generating", createdAt: 10)
        generating.status = .generating
        try store.save(generating)
        try writeGenerationOwner(getpid(), itemID: generating.id, store: store)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false }
        )
        defer { controller.shutdown() }

        controller.start()

        #expect(controller.playerListItems.map(\.id) == [generating.id])
        #expect(controller.queuedItems.isEmpty)
        #expect(controller.currentItem == nil)
        #expect(controller.isGenerating)
    }

    @Test @MainActor
    func explicitQueueSelectionClearsPauseAllAndDoesNotDuplicateItem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.mp3")
        try Data().write(to: audio)
        let store = QueueStore(stateDirectory: directory)
        let queued = item(id: "selected", createdAt: 10, outputFile: audio.path)
        try store.save(queued)
        try store.setGlobalPlaybackPaused(true)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(queued)

        #expect(!controller.isGloballyPaused)
        #expect(!store.isGlobalPlaybackPaused())
        #expect(try store.loadItems().map(\.id) == [queued.id])
        #expect(try store.loadItems().map(\.status) == [.queued])
    }

    @Test @MainActor
    func explicitRecentSelectionRequeuesTheOriginalItemAndClearsPauseAll() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("speech.mp3")
        try Data().write(to: audio)
        let store = QueueStore(stateDirectory: directory)
        var recent = item(id: "recent", createdAt: 10, outputFile: audio.path)
        recent.status = .played
        try store.save(recent)
        try store.setGlobalPlaybackPaused(true)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(recent)

        let items = try store.loadItems()
        #expect(!controller.isGloballyPaused)
        #expect(items.count == 1)
        #expect(items.first?.id == recent.id)
        #expect(items.first?.createdAt == recent.createdAt)
        #expect(items.first?.status == .queued)
    }

    @Test
    func storesIndependentPlaybackRatesForEachVoice() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoicePlaybackRateStore(stateDirectory: directory)

        #expect(store.rate(for: "af_bella") == 1.0)

        try store.save(1.5, for: "af_bella")
        try store.save(0.75, for: "am_michael")

        let reloaded = VoicePlaybackRateStore(stateDirectory: directory)
        #expect(reloaded.rate(for: "af_bella") == 1.5)
        #expect(reloaded.rate(for: "am_michael") == 0.75)
        #expect(reloaded.rate(for: "af_nova") == 1.0)
    }

    @Test
    func cyclesThroughCompactPlayerRatesAndWraps() {
        #expect(VoicePlaybackRateStore.nextRate(after: 0.75) == 1.0)
        #expect(VoicePlaybackRateStore.nextRate(after: 1.0) == 1.25)
        #expect(VoicePlaybackRateStore.nextRate(after: 1.25) == 1.5)
        #expect(VoicePlaybackRateStore.nextRate(after: 1.5) == 2.0)
        #expect(VoicePlaybackRateStore.nextRate(after: 2.0) == 0.75)
        #expect(VoicePlaybackRateStore.nextRate(after: 1.1) == 1.0)
        #expect(VoicePlaybackRateStore.label(for: 1.25) == "1.25×")
    }

    @Test
    func ignoresUnsupportedStoredPlaybackRate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = VoicePlaybackRateStore(stateDirectory: directory)
        try Data(#"{"af_bella":1.1}"#.utf8).write(to: store.fileURL)

        #expect(store.rate(for: "af_bella") == 1.0)
    }

    @Test
    func replayKeepsGenerationIdentityAndReturnsToQueue() {
        var original = item(id: "done", createdAt: 10)
        original.status = .played
        original.startedAt = 11
        original.completedAt = 12
        original.wordTimings = [timing("A", 0, 0.2)]
        original.attachments = [attachment()]
        original.assetDirectory = "/tmp/brief"
        original.iTermSessionID = "w1t2p3:9473B74C-9371-4C44-B34C-84F40E3D2F04"
        original.summary = "The implementation is complete and two decisions remain."
        original.primaryMessage = "The implementation is complete. Two decisions remain."

        let replay = original.requeuedForReplay()

        #expect(replay.id == original.id)
        #expect(replay.text == original.text)
        #expect(replay.subject == original.subject)
        #expect(replay.summary == original.summary)
        #expect(replay.agentName == original.agentName)
        #expect(replay.sessionID == original.sessionID)
        #expect(replay.iTermSessionID == original.iTermSessionID)
        #expect(replay.status == .queued)
        #expect(replay.createdAt == original.createdAt)
        #expect(replay.startedAt == nil)
        #expect(replay.completedAt == nil)
        #expect(replay.playbackOffset == nil)
        #expect(replay.wordTimings == original.wordTimings)
        #expect(replay.attachments == original.attachments)
        #expect(replay.assetDirectory == original.assetDirectory)
        #expect(replay.primaryMessage == original.primaryMessage)
    }

    @Test
    func showsRelativeHistoryTimesForTheFirstDay() {
        let now = Date(timeIntervalSince1970: 200_000)

        #expect(item(id: "now", createdAt: 199_970).timestampLabel(now: now) == "just now")
        #expect(item(id: "minutes", createdAt: 199_700).timestampLabel(now: now) == "5m ago")
        #expect(item(id: "hours", createdAt: 189_200).timestampLabel(now: now) == "3h ago")
    }

    @Test
    func switchesHistoryTimesToAbsoluteAtTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 200_000)
        let label = item(id: "day-old", createdAt: 113_600).timestampLabel(now: now)

        #expect(label != "24h ago")
        #expect(!label.hasSuffix("ago"))
    }

    @Test
    func schedulesHistoryTimestampRefreshesOnlyWhenLabelsCanChange() {
        let now = Date(timeIntervalSince1970: 200_000)
        let recent = item(id: "recent", createdAt: 199_970)
        let minutes = item(id: "minutes", createdAt: 199_700)
        let hours = item(id: "hours", createdAt: 189_200)
        let absolute = item(id: "absolute", createdAt: 100_000)

        #expect(HistoryTimestampPolicy.nextUpdate(after: now, items: [recent]) == Date(timeIntervalSince1970: 200_030))
        #expect(HistoryTimestampPolicy.nextUpdate(after: now, items: [minutes]) == Date(timeIntervalSince1970: 200_060))
        #expect(HistoryTimestampPolicy.nextUpdate(after: now, items: [hours]) == Date(timeIntervalSince1970: 203_600))
        #expect(HistoryTimestampPolicy.nextUpdate(after: now, items: [absolute]) == .distantFuture)
        #expect(HistoryTimestampPolicy.nextUpdate(after: now, items: [hours, recent]) == Date(timeIntervalSince1970: 200_030))
    }

    @Test @MainActor
    func historyTimestampClockStaysQuietUntilTheNextLabelBoundary() {
        let clock = HistoryTimestampClock(now: Date(timeIntervalSince1970: 200_000))
        let recent = item(id: "recent", createdAt: 199_970)
        var changes = 0
        let observation = clock.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        clock.update(items: [recent], at: Date(timeIntervalSince1970: 200_000), reschedule: true)
        let changesAfterScheduling = changes
        clock.update(items: [recent], at: Date(timeIntervalSince1970: 200_029))
        #expect(changes == changesAfterScheduling)

        clock.update(items: [recent], at: Date(timeIntervalSince1970: 200_030))
        #expect(changes == changesAfterScheduling + 1)
    }

    @Test
    func assignsIndependentStableColorsToAgentsAndProjects() {
        let agent = WorkspaceAccent.paletteIndex(forStableLabel: "agent:clay-river-860")
        let agentAgain = WorkspaceAccent.paletteIndex(forStableLabel: "agent:clay-river-860")
        let project = WorkspaceAccent.paletteIndex(forStableLabel: "skills")

        #expect(agent == agentAgain)
        #expect(agent != project)
    }

    @Test @MainActor
    func archivesAndRestoresRecentSpeechWithoutDeletingIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var recent = item(id: "recent", createdAt: 10)
        recent.status = .played
        try store.save(recent)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory)
        )
        defer { controller.shutdown() }
        controller.start()

        controller.setArchived(true, for: recent)
        #expect(controller.activeHistoryItems.isEmpty)
        #expect(controller.archivedHistoryItems.map(\.id) == [recent.id])
        #expect(try store.loadItems().first?.archived == true)

        let archived = try #require(controller.archivedHistoryItems.first)
        controller.setArchived(false, for: archived)
        #expect(controller.activeHistoryItems.map(\.id) == [recent.id])
        #expect(controller.archivedHistoryItems.isEmpty)
    }

}
