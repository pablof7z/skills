import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TTSMenuBar

struct QueueStoreTests {
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
        store.setPausesMedia(false)
        store.setMediaHandoffDelay(1.5)
        store.setMediaResumeDelay(4.5)

        let reloaded = PlayerPreferencesStore(stateDirectory: directory)
        #expect(!reloaded.preferences.pausesMedia)
        #expect(reloaded.preferences.mediaHandoffDelay == 1.5)
        #expect(reloaded.preferences.mediaResumeDelay == 4.5)
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
        original.primaryMessage = "The implementation is complete. Two decisions remain."

        let replay = original.requeuedForReplay()

        #expect(replay.id == original.id)
        #expect(replay.text == original.text)
        #expect(replay.subject == original.subject)
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

    @Test
    func createsAssociatedAttachmentPlaybackThatCanReturnToParent() throws {
        var brief = item(id: "brief", createdAt: 10)
        brief.attachments = [attachment()]
        let value = try #require(
            brief.attachmentPlaybackItem(attachment(), now: 20, returnTo: 12.5)
        )

        #expect(value.isAttachmentPlayback)
        #expect(value.parentItemID == "brief")
        #expect(value.attachmentID == "why")
        #expect(value.returnToPlaybackOffset == 12.5)
        #expect(value.outputFile == "/tmp/why.mp3")
        #expect(value.text == "# Why this matters\n\nUseful detail.")
        #expect(value.subject == "Why this matters")
        #expect(value.attachments == brief.attachments)
        #expect(value.status == .queued)
    }

    @Test @MainActor
    func supplementalPlaybackDoesNotInflateVisibleQueueOrHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let main = item(id: "main", createdAt: 10)
        var supplemental = item(id: "supplemental", createdAt: 20)
        supplemental.parentItemID = "main"
        supplemental.attachmentID = "why"
        try store.save(main)
        try store.save(supplemental)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }

        controller.start()

        #expect(controller.queuedItems.map(\.id) == ["main"])
    }

    @Test @MainActor
    func repeatedAttachmentClicksReusePendingPlayback() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioFile = directory.appendingPathComponent("why.mp3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: audioFile)
        var why = attachment()
        why.audioFile = audioFile.path
        var main = item(id: "main", createdAt: 10)
        main.attachments = [why]
        let store = QueueStore(stateDirectory: directory)
        try store.save(main)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }
        controller.start()

        #expect(why.isPlayable)
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
        #expect(controller.items.map(\.id) == [main.id])

        controller.playAttachment(why, from: main)
        #expect(controller.items.filter(\.isAttachmentPlayback).count == 1)
        controller.playAttachment(why, from: main)

        let children = try store.loadItems().filter { $0.isAttachmentPlayback }
        #expect(children.count == 1)
        #expect(children.first?.parentItemID == main.id)
        #expect(children.first?.attachmentID == why.id)
    }

    @Test @MainActor
    func explicitlyRequestedAttachmentPlaysBeforeOrdinaryQueue() throws {
        let ordinary = item(id: "ordinary", createdAt: 10)
        var attachmentPlayback = item(id: "attachment", createdAt: 20)
        attachmentPlayback.parentItemID = "main"
        attachmentPlayback.attachmentID = "why"

        let next = try #require(
            PlaybackController.nextQueuedItem(in: [ordinary, attachmentPlayback])
        )

        #expect(next.id == attachmentPlayback.id)
    }

    @Test
    func playbackStateSaveCannotClobberPreparedAttachmentAudio() throws {
        var stale = attachment()
        stale.status = .preparing
        stale.audioFile = "/tmp/pending.mp3"
        stale.wordTimings = nil
        var prepared = attachment()
        prepared.status = .ready

        let merged = QueueStore.mergingPreparedAttachments([stale], with: [prepared])

        #expect(merged == [prepared])
        #expect(QueueStore.mergingPreparedAttachments(nil, with: [prepared]) == [prepared])
    }

    @Test
    func attachmentLoadsCopiedMarkdownOnlyWhenNeeded() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.md")
        try Data("# Durable detail\n\nThe copied file owns this text.".utf8).write(to: source)
        var value = attachment()
        value.sourceFile = source.path
        value.text = nil

        #expect(value.displayText == "# Durable detail\n\nThe copied file owns this text.")
    }

    @Test
    func replayCanStartAtRequestedPlaybackOffset() {
        let original = item(id: "done", createdAt: 10)

        let replay = original.requeuedForReplay(startingAt: 42.5)

        #expect(replay.status == .queued)
        #expect(replay.playbackOffset == 42.5)
    }

    @Test
    func preservesRetryCommandWhenSavingAndLoadingItem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var failed = item(id: "failed", createdAt: 10)
        failed.status = .failed
        failed.retryCommand = "/tmp/tts"

        try store.save(failed)

        #expect(try store.loadItems().first?.retryCommand == "/tmp/tts")
    }

    @Test
    func tracksUnreadStateAndGenerationDuration() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var generating = item(id: "generating", createdAt: 10)
        generating.generationDuration = 18
        generating.isUnheard = true

        try store.save(generating)

        let loaded = try #require(store.loadItems().first)
        #expect(loaded.generationDuration == 18)
        #expect(loaded.unheard)
    }

    @Test
    func estimatesGenerationProgressFromRecentSuccessfulSamples() {
        var current = item(id: "current", createdAt: 100)
        current.text = Array(repeating: "word", count: 100).joined(separator: " ")
        var first = item(id: "first", createdAt: 10)
        first.text = Array(repeating: "word", count: 100).joined(separator: " ")
        first.status = .played
        first.generationDuration = 20
        var second = first
        second.id = "second"
        second.generationDuration = 24

        let early = GenerationProgress.value(
            for: current,
            samples: [first, second],
            now: Date(timeIntervalSince1970: 110)
        )
        let late = GenerationProgress.value(
            for: current,
            samples: [first, second],
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(early > 0.04)
        #expect(early < 0.94)
        #expect(late > 0.93)
        #expect(late <= 0.94)
    }

    @Test
    func keepsFullSessionIdentifierForDisplay() {
        var value = item(id: "session", createdAt: 10)
        value.sessionID = "019c-live-menu-uat-full-session"

        #expect(value.sessionLabel == "019c-live-menu-uat-full-session")
    }

    @Test
    func keepsOptionalSubjectForDisplay() {
        var value = item(id: "subject", createdAt: 10)
        value.subject = "Queue ownership is now explicit"

        #expect(value.subjectLabel == "Queue ownership is now explicit")
    }

    @Test
    func buildsNowSpeakingContextFromAgentAndNonGitDirectoryPath() {
        var value = item(id: "hud", createdAt: 10)
        value.subject = "The passive speaking cue is ready"
        value.agentName = "river-codex"
        value.workspace = "/not-a-repository/example-workspace"

        #expect(value.nowSpeakingTitle == "The passive speaking cue is ready")
        #expect(value.workspaceDisplayLabel == "/not-a-repository/example-workspace")
        #expect(value.nowSpeakingContext == "river-codex · /not-a-repository/example-workspace")
    }

    @Test
    func buildsProjectAgentLabelWithProjectFirst() {
        var value = item(id: "player-history", createdAt: 10)
        value.agentName = "river-codex"
        value.workspace = "/not-a-repository/example-workspace"

        #expect(value.projectAgentLabel == "example-workspace - river-codex")
    }

    @Test
    func projectAgentLabelFallsBackToAgentWithoutWorkspace() {
        var value = item(id: "player-history-no-workspace", createdAt: 10)
        value.agentName = "river-codex"
        value.workspace = nil

        #expect(value.projectAgentLabel == "river-codex")
    }

    @Test
    func fallsBackToSpokenTextWhenSubjectIsMissing() {
        var value = item(id: "no-subject", createdAt: 10)
        value.subject = nil

        #expect(value.nowSpeakingTitle == value.text)
    }

    @Test
    func derivesStableAccentFromGitProjectRoot() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("recognizable-project", isDirectory: true)
        let nested = project.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(WorkspaceAccent.projectLabel(forWorkspacePath: nested.path) == "recognizable-project")
        #expect(WorkspaceAccent.displayLabel(forWorkspacePath: nested.path) == "recognizable-project")
        #expect(
            WorkspaceAccent.paletteIndex(forWorkspacePath: nested.path)
                == WorkspaceAccent.paletteIndex(forWorkspacePath: project.path)
        )
    }

    @Test
    func recognizesGitWorktreeMarkerFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("recognizable-project", isDirectory: true)
        let worktreeGitDirectory = project
            .appendingPathComponent(".git/worktrees/feature", isDirectory: true)
        let worktree = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let nested = worktree.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeGitDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(
            to: worktreeGitDirectory.appendingPathComponent("commondir")
        )
        try Data("gitdir: \(worktreeGitDirectory.path)\n".utf8).write(
            to: worktree.appendingPathComponent(".git")
        )

        #expect(WorkspaceAccent.projectLabel(forWorkspacePath: nested.path) == "recognizable-project")
        #expect(WorkspaceAccent.displayLabel(forWorkspacePath: nested.path) == "recognizable-project")
        #expect(WorkspaceAccent.worktreeLabel(forWorkspacePath: nested.path) == "feature-worktree")
        #expect(
            WorkspaceAccent.paletteIndex(forWorkspacePath: nested.path)
                == WorkspaceAccent.paletteIndex(forWorkspacePath: project.path)
        )
    }

    @Test
    func fallsBackToWorkspaceBasenameOutsideGit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("standalone-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let index = WorkspaceAccent.paletteIndex(forWorkspacePath: workspace.path)

        #expect(WorkspaceAccent.projectLabel(forWorkspacePath: workspace.path) == "standalone-workspace")
        #expect(WorkspaceAccent.displayLabel(forWorkspacePath: workspace.path) == workspace.path)
        #expect(index >= 0 && index < WorkspaceAccent.count)
        #expect(index == WorkspaceAccent.paletteIndex(forWorkspacePath: workspace.path))
    }

    @Test
    func usesRealWordTimingInsideNaturalPhrases() throws {
        let text = "Natural phrasing guides the eye. Short pauses help."
        let timings = [
            timing("Natural", 0.02, 0.36),
            timing("phrasing", 0.36, 0.82),
            timing("guides", 0.82, 1.08),
            timing("the", 1.08, 1.18),
            timing("eye", 1.18, 1.55),
            timing(".", 1.55, 1.78),
            timing("Short", 1.92, 2.22),
            timing("pauses", 2.22, 2.62),
            timing("help", 2.62, 2.94),
            timing(".", 2.94, 3.08),
        ]

        let document = TranscriptDocument.build(text: text, timings: timings, duration: 3.08)
        let state = document.playbackState(at: 1.12, duration: 3.08)

        #expect(document.words.count == 8)
        #expect(document.phrases.count == 2)
        #expect(state.activeWordIndex == 3)
        #expect(state.activePhraseIndex == 0)
        #expect(document.seekTime(forWordAt: 5, duration: 3.08) == 1.92)
        let secondPhrase = try #require(document.phrases.last)
        #expect((text as NSString).substring(with: secondPhrase.range) == "Short pauses help")
    }

    @Test
    func alignsVisibleMessageAfterSpokenFraming() throws {
        let text = "The agent message starts here.\n\n• First point"
        let timings = [
            timing("Agent", 0.0, 0.3),
            timing("River", 0.3, 0.6),
            timing("speaking", 0.6, 1.0),
            timing(".", 1.0, 1.1),
            timing("A", 1.2, 1.3),
            timing("short", 1.3, 1.5),
            timing("subject", 1.5, 1.8),
            timing(".", 1.8, 1.9),
            timing("The", 2.2, 2.35),
            timing("agent", 2.35, 2.6),
            timing("message", 2.6, 2.95),
            timing("starts", 2.95, 3.2),
            timing("here", 3.2, 3.5),
            timing(".", 3.5, 3.6),
            timing("First", 3.8, 4.1),
            timing("point", 4.1, 4.4),
        ]

        let document = TranscriptDocument.build(text: text, timings: timings, duration: 4.4)

        #expect(document.words.first?.startTime == 2.2)
        #expect(document.playbackState(at: 1.5, duration: 4.4).activeWordIndex == nil)
        #expect(document.playbackState(at: 2.4, duration: 4.4).activeWordIndex == 1)
        #expect(document.seekTime(forWordAt: 5, duration: 4.4) == 3.8)
    }

    @Test
    func rendersMarkdownAsStructuredTranscriptText() {
        let rendered = TranscriptMarkdown.render(
            "# Update\n\n- **First** item\n- `Second` item",
            accent: .systemPink
        )

        #expect(rendered.string == "Update\n\n• First item\n• Second item")
    }

    @Test
    func rendersTaskItemsAsDistinctCheckboxes() {
        let rendered = TranscriptMarkdown.render(
            "- [ ] Still open\n- [x] Already done",
            accent: .systemPink
        )

        #expect(rendered.string == "☐  Still open\n☑  Already done")
        let checkedRange = (rendered.string as NSString).range(of: "Already done")
        let style = rendered.attribute(.strikethroughStyle, at: checkedRange.location, effectiveRange: nil) as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    @Test
    func rendersMarkdownTableAsStyledCellsWithoutPipeScaffolding() {
        let rendered = TranscriptMarkdown.render(
            """
            | Claim | Method |
            |:------|-------:|
            | API exists | source inspection |
            """,
            accent: .systemPink
        )

        #expect(rendered.string == "Claim\nMethod\nAPI exists\nsource inspection\n")
        #expect(!rendered.string.contains("|"))

        let claimParagraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(claimParagraph?.textBlocks.first is NSTextTableBlock)
        #expect(claimParagraph?.alignment == .left)

        let methodRange = (rendered.string as NSString).range(of: "Method")
        let methodParagraph = rendered.attribute(
            .paragraphStyle,
            at: methodRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(methodParagraph?.alignment == .right)
    }

    @Test
    @MainActor
    func structuredMarkdownLaysOutWithinTheTranscriptWidth() {
        let rendered = TranscriptMarkdown.render(
            """
            | Claim | Method | Result |
            |:------|:-------|-------:|
            | API exists | source inspection | verified |
            | App fold | unit test | passing |

            - [ ] Failure path remains explicit
            - [x] Happy path verified
            """,
            accent: .systemPink
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.containerSize = NSSize(width: 744, height: 1_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(rendered)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            Issue.record("NSTextView did not provide its text system")
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        #expect(usedRect.width <= textContainer.containerSize.width)
        #expect(usedRect.height > 100)
    }

    @Test
    func preservesPipesInsideTableCodeSpans() {
        let rendered = TranscriptMarkdown.render(
            """
            | Expression | Meaning |
            | --- | --- |
            | `left | right` | alternatives |
            """,
            accent: .systemPink
        )

        #expect(rendered.string.contains("left | right"))
        #expect(rendered.string.contains("alternatives"))
    }

    @Test
    func rendersLanguageTaggedCodeBlockWithLabelAndCode() {
        let source = """
        Here is a snippet:

        ```ts
        const x = 5;
        ```
        Done.
        """
        let rendered = TranscriptMarkdown.render(source, accent: .systemPink)

        #expect(rendered.string == "Here is a snippet:\n\nTS\nconst x = 5;\n\nDone.")
    }

    @Test
    func hidesSpeechOnlyCodeDescriptionFromTranscript() {
        let rendered = TranscriptMarkdown.render(
            """
            ```swift
            let passed = true
            ```
            ["The Swift sample returns true."]
            """,
            accent: .systemPink
        )

        #expect(rendered.string.contains("let passed = true"))
        #expect(!rendered.string.contains("The Swift sample returns true"))
    }

    @Test
    func excludesLanguageTaggedCodeFromReadAlongTiming() throws {
        let rendered = TranscriptMarkdown.render(
            """
            Before code.
            ```swift
            let passed = true
            ```
            ["The Swift sample describes a true result in detail."]
            After code.
            """,
            accent: .systemPink
        )
        let timings = [
            timing("Before", 0.0, 0.3),
            timing("code", 0.3, 0.5),
            timing("The", 0.7, 0.9),
            timing("Swift", 0.9, 1.2),
            timing("sample", 1.2, 1.5),
            timing("describes", 1.5, 1.9),
            timing("a", 1.9, 2.0),
            timing("true", 2.0, 2.2),
            timing("result", 2.2, 2.5),
            timing("in", 2.5, 2.6),
            timing("detail", 2.6, 3.0),
            timing("After", 3.2, 3.5),
            timing("code", 3.5, 3.8),
        ]

        let document = TranscriptDocument.build(
            attributedText: rendered,
            timings: timings,
            duration: 3.8
        )
        let codeRange = (rendered.string as NSString).range(of: "passed")
        let afterRange = (rendered.string as NSString).range(of: "After")

        #expect(document.words.count == 4)
        #expect(document.wordIndex(at: codeRange.location) == nil)
        #expect(document.playbackState(at: 1.5, duration: 3.8).activeWordIndex == nil)
        #expect(document.wordIndex(at: afterRange.location) == 2)
        #expect(document.playbackState(at: 3.3, duration: 3.8).activeWordIndex == 2)
        #expect(document.seekTime(forWordAt: 2, duration: 3.8) == 3.2)
    }

    @Test
    func rendersBareCodeBlockWithoutLabel() {
        let source = """
        Run this:

        ```
        echo hello
        ```
        Done.
        """
        let rendered = TranscriptMarkdown.render(source, accent: .systemPink)

        #expect(rendered.string == "Run this:\n\n\necho hello\n\nDone.")
        let codeRange = (rendered.string as NSString).range(of: "echo")
        #expect(rendered.attribute(
            .transcriptNonSpoken,
            at: codeRange.location,
            effectiveRange: nil
        ) == nil)
    }

    @Test
    func highlightsKeywordsInLanguageTaggedCodeBlock() {
        let source = """
        ```swift
        let x = 5
        ```
        """
        let rendered = TranscriptMarkdown.render(source, accent: .systemPink)

        let string = rendered.string
        #expect(string.contains("SWIFT"))
        #expect(string.contains("let x = 5"))

        let keywordColor = NSColor(calibratedRed: 0.55, green: 0.34, blue: 0.92, alpha: 1.0)
        var foundKeywordColor = false
        rendered.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: rendered.length),
            options: []
        ) { value, _, stop in
            if let color = value as? NSColor, color == keywordColor {
                foundKeywordColor = true
                stop.pointee = true
            }
        }
        #expect(foundKeywordColor)
        let codeRange = (rendered.string as NSString).range(of: "let")
        #expect(rendered.attribute(
            .transcriptNonSpoken,
            at: codeRange.location,
            effectiveRange: nil
        ) as? Bool == true)
    }

    @Test
    func mermaidPreviewLoadsRendererAndKeepsReadableFallback() {
        let source = "flowchart LR\nA[Message] --> B{Type}"
        let document = MermaidHTML.document(source: source, darkMode: true, accentHue: 87)

        #expect(document.contains("mermaid@11"))
        #expect(document.contains("mermaid.render"))
        #expect(document.contains("Diagram preview unavailable"))
        #expect(document.contains("flowchart LR\\nA[Message] --> B{Type}"))
    }

    @Test
    func measuredPauseCreatesPhraseWithoutPunctuation() {
        let text = "A calm phrase then another thought"
        let timings = [
            timing("A", 0, 0.1),
            timing("calm", 0.1, 0.4),
            timing("phrase", 0.4, 0.8),
            timing("then", 1.2, 1.5),
            timing("another", 1.5, 1.9),
            timing("thought", 1.9, 2.2),
        ]

        let document = TranscriptDocument.build(text: text, timings: timings, duration: 2.2)

        #expect(document.phrases.map(\.wordRange) == [0..<3, 3..<6])
    }

    @Test
    func legacyTranscriptShowsPhraseProgressWithoutFakeWordPrecision() {
        let document = TranscriptDocument.build(
            text: "First sentence. Second sentence.",
            timings: nil,
            duration: 10
        )
        let state = document.playbackState(at: 7, duration: 10)

        #expect(state.activeWordIndex == nil)
        #expect(state.activePhraseIndex == 1)
        #expect(document.seekTime(forWordAt: 2, duration: 10) == 5)
    }

    @Test
    func lingerCountdownPreservesRemainingTimeAcrossHoverPause() {
        var countdown = LingerCountdown(duration: 8)
        countdown.start(at: 100)

        countdown.pause(at: 103)
        #expect(countdown.timeRemaining(at: 150) == 5)

        countdown.resume(at: 150)
        #expect(countdown.timeRemaining(at: 152) == 3)

        countdown.pause(at: 154)
        #expect(countdown.timeRemaining(at: 300) == 1)

        countdown.cancel()
        #expect(countdown.timeRemaining(at: 300) == 8)
    }

    @Test
    func pendingQuestionRetentionIdentifiesUnresolvedItems() {
        var question = item(id: "pending-question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        var answered = question
        answered.questionStatus = .answered

        #expect(PendingQuestionRetention.shouldRetain(
            lastCurrentItem: question,
            lingeringItem: nil
        ))
        #expect(PendingQuestionRetention.shouldRetain(
            lastCurrentItem: nil,
            lingeringItem: question
        ))
        #expect(!PendingQuestionRetention.shouldRetain(
            lastCurrentItem: answered,
            lingeringItem: nil
        ))
        #expect(PendingQuestionRetention.retainedItem(
            currentItem: nil,
            lingeringItem: question,
            lastCurrentItem: nil
        )?.id == question.id)
    }

    @Test
    func playerBackNavigationSuppressesOnlyTheCurrentItem() {
        #expect(!PlayerHistoryToolbarPolicy.rootItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.backItemIdentifier
        ))
        #expect(PlayerHistoryToolbarPolicy.allowedItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.backItemIdentifier
        ))
        #expect(!PlayerNavigationPolicy.shouldDisplay(
            itemID: "question",
            hiddenItemID: "question"
        ))
        #expect(PlayerNavigationPolicy.shouldDisplay(
            itemID: "next-update",
            hiddenItemID: "question"
        ))
        #expect(PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: "question",
            currentlyHidden: "question"
        ) == "question")
        #expect(PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: "next-update",
            currentlyHidden: "question"
        ) == nil)
    }

    @Test
    func playerHoverRetainsFinishedContentThroughTheExitGracePeriod() {
        #expect(PlayerHoverContinuation.shouldRetainCurrentContent(
            isHovered: true,
            isGracePeriodActive: false,
            hasCurrentContent: true
        ))
        #expect(PlayerHoverContinuation.shouldRetainCurrentContent(
            isHovered: false,
            isGracePeriodActive: true,
            hasCurrentContent: true
        ))
        #expect(!PlayerHoverContinuation.shouldRetainCurrentContent(
            isHovered: false,
            isGracePeriodActive: false,
            hasCurrentContent: true
        ))
    }

    @Test
    func completedPendingQuestionAudioRemainsReplayableFromItsAnswerView() {
        var question = item(id: "pending-question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        question.status = .played

        #expect(QuestionAudioReview.canReplay(question, fileExists: { _ in true }))
        #expect(!QuestionAudioReview.canReplay(question, fileExists: { _ in false }))

        question.status = .generating
        #expect(!QuestionAudioReview.canReplay(question, fileExists: { _ in true }))

        question.status = .played
        question.kind = .speech
        question.questionStatus = nil
        #expect(!QuestionAudioReview.canReplay(question, fileExists: { _ in true }))
    }

    @Test
    func unchangedHUDLayoutDoesNotRequestAnotherAnimation() {
        let frame = CGRect(x: 20, y: 20, width: 540, height: 470)

        #expect(!HUDLayoutUpdate.isNeeded(
            currentFrame: frame,
            targetFrame: frame,
            currentAlpha: 1,
            targetAlpha: 1
        ))
        #expect(HUDLayoutUpdate.isNeeded(
            currentFrame: frame,
            targetFrame: CGRect(x: 20, y: 20, width: 470, height: 226),
            currentAlpha: 1,
            targetAlpha: 1
        ))
        #expect(HUDLayoutUpdate.isNeeded(
            currentFrame: frame,
            targetFrame: frame,
            currentAlpha: 0.84,
            targetAlpha: 1
        ))
    }

    @Test
    func decodesExistingQueueItemsWithoutNewOptionalFields() throws {
        let data = try JSONEncoder().encode(item(id: "legacy", createdAt: 10))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "subject")
        object.removeValue(forKey: "playback_offset")
        object.removeValue(forKey: "word_timings")
        object.removeValue(forKey: "attachments")
        object.removeValue(forKey: "asset_directory")
        object.removeValue(forKey: "parent_item_id")
        object.removeValue(forKey: "attachment_id")
        object.removeValue(forKey: "return_to_playback_offset")
        object.removeValue(forKey: "iterm_session_id")
        object.removeValue(forKey: "is_archived")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TTSItem.self, from: legacyData)

        #expect(decoded.subject == nil)
        #expect(decoded.playbackOffset == nil)
        #expect(decoded.wordTimings == nil)
        #expect(decoded.attachments == nil)
        #expect(decoded.assetDirectory == nil)
        #expect(decoded.iTermSessionID == nil)
        #expect(!decoded.archived)
        #expect(!decoded.isAttachmentPlayback)
    }

    @Test
    func parsesOnlyCanonicalITermSessionTargets() throws {
        let prefixed = try #require(
            AgentSessionTarget(rawIdentifier: "w5t13p3:9473B74C-9371-4C44-B34C-84F40E3D2F04")
        )
        let plain = try #require(
            AgentSessionTarget(rawIdentifier: "9473b74c-9371-4c44-b34c-84f40e3d2f04")
        )

        #expect(prefixed.uniqueID == "9473B74C-9371-4C44-B34C-84F40E3D2F04")
        #expect(plain == prefixed)
        #expect(AgentSessionTarget(rawIdentifier: nil) == nil)
        #expect(AgentSessionTarget(rawIdentifier: "not-a-session") == nil)
    }

    @Test @MainActor
    func exposesSessionControlOnlyWhileTargetIsReachable() {
        let scripting = TestITermSessionScripting()
        let opener = AgentSessionOpener(scripting: scripting, probeInterval: 1)
        let identifier = "w5t13p3:9473B74C-9371-4C44-B34C-84F40E3D2F04"

        opener.refresh(rawIdentifier: nil, force: true, uptime: 1)
        #expect(!opener.canOpen(rawIdentifier: identifier))

        scripting.existingSessionIDs.insert("9473B74C-9371-4C44-B34C-84F40E3D2F04")
        opener.refresh(rawIdentifier: identifier, force: true, uptime: 2)
        #expect(opener.canOpen(rawIdentifier: identifier))

        scripting.existingSessionIDs.removeAll()
        opener.refresh(rawIdentifier: identifier, force: true, uptime: 3)
        #expect(!opener.canOpen(rawIdentifier: identifier))
    }

    @Test @MainActor
    func opensOnlyTheResolvedSession() {
        let scripting = TestITermSessionScripting()
        let identifier = "w5t13p3:9473B74C-9371-4C44-B34C-84F40E3D2F04"
        scripting.existingSessionIDs.insert("9473B74C-9371-4C44-B34C-84F40E3D2F04")
        let opener = AgentSessionOpener(scripting: scripting, probeInterval: 1)

        opener.refresh(rawIdentifier: identifier, force: true, uptime: 1)
        opener.open(rawIdentifier: identifier)

        #expect(scripting.selectedSessionIDs == ["9473B74C-9371-4C44-B34C-84F40E3D2F04"])
    }

    @Test
    func allowsOnlyOneMenuInstancePerStateDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let first = MenuInstanceLock(store: store)
        let second = MenuInstanceLock(store: store)

        #expect(try first.acquire(processID: 111))
        #expect(try !second.acquire(processID: 222))
        #expect(try String(contentsOf: store.processFile, encoding: .utf8) == "111\n")

        first.release()

        #expect(try second.acquire(processID: 222))
        #expect(try String(contentsOf: store.processFile, encoding: .utf8) == "222\n")
        second.release()
    }

    @Test
    func answersQuestionWithEditableSuggestionAndRejectsSecondAnswer() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var question = item(id: "question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        question.suggestions = [TTSSuggestion(title: "Ship it", description: "Proceed now")]
        try store.save(question)

        let answered = try store.answer(
            id: question.id,
            answer: "Ship it after tests",
            suggestionIndex: 0,
            now: 20
        )

        #expect(answered.questionStatus == .answered)
        #expect(answered.response?.answer == "Ship it after tests")
        #expect(answered.response?.suggestionIndex == 0)
        #expect(answered.response?.modified == true)
        #expect(answered.response?.answeredAt == 20)
        #expect(throws: QueueOperationError.questionAlreadyResolved(question.id)) {
            try store.answer(id: question.id, answer: "A conflicting answer")
        }
    }

    @Test
    func playbackSaveCannotClobberTerminalQuestionResponse() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var stalePlaybackCopy = item(id: "question", createdAt: 10)
        stalePlaybackCopy.kind = .question
        stalePlaybackCopy.questionStatus = .pending
        try store.save(stalePlaybackCopy)
        _ = try store.answer(id: stalePlaybackCopy.id, answer: "Durable answer", now: 20)

        stalePlaybackCopy.status = .played
        try store.save(stalePlaybackCopy)

        let loaded = try store.item(id: stalePlaybackCopy.id)
        let persisted = try #require(loaded)
        #expect(persisted.status == .played)
        #expect(persisted.questionStatus == .answered)
        #expect(persisted.response?.answer == "Durable answer")
    }

    @Test
    func stalePlaybackSaveCannotRestoreConcurrentlyArchivedItem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var stalePlaybackCopy = item(id: "archived", createdAt: 10)
        stalePlaybackCopy.isArchived = false
        try store.save(stalePlaybackCopy)
        _ = try store.setArchived(
            true,
            id: stalePlaybackCopy.id,
            reason: "Superseded by another agent",
            actor: "coordinator",
            now: 20
        )

        stalePlaybackCopy.status = .played
        try store.save(stalePlaybackCopy)

        let loaded = try store.item(id: stalePlaybackCopy.id)
        let persisted = try #require(loaded)
        #expect(persisted.status == .played)
        #expect(persisted.archived)
        #expect(persisted.archivedAt == 20)
        #expect(persisted.archiveReason == "Superseded by another agent")
        #expect(persisted.archivedBy == "coordinator")
    }

    @Test
    func supersessionArchivesSourcesAndWritesAuditRecord() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        for id in ["first", "second"] {
            var question = item(id: id, createdAt: 10)
            question.kind = .question
            question.questionStatus = .pending
            try store.save(question)
        }
        var replacement = item(id: "replacement", createdAt: 20)
        replacement.kind = .question
        replacement.questionStatus = .pending
        try store.save(replacement)

        let updated = try store.supersede(
            sourceIDs: ["first", "second"],
            with: ["replacement"],
            reason: "Combined missing nuance",
            actor: "test-agent",
            now: 30
        )

        #expect(updated.allSatisfy { $0.questionStatus == .superseded && $0.archived })
        #expect(updated.allSatisfy { $0.supersededBy == ["replacement"] })
        #expect(updated.allSatisfy { $0.archiveReason == "Combined missing nuance" })
        let audits = try FileManager.default.contentsOfDirectory(
            at: store.operationsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(audits.count == 1)
        let audit = try JSONDecoder().decode(QueueOperation.self, from: Data(contentsOf: audits[0]))
        #expect(audit.kind == .supersede)
        #expect(audit.sourceIDs == ["first", "second"])
        #expect(audit.replacementIDs == ["replacement"])
        #expect(audit.actor == "test-agent")
    }

    @Test
    func supersessionRejectsMissingReplacementAndResolvedSource() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var question = item(id: "question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        try store.save(question)

        #expect(throws: QueueOperationError.itemNotFound("missing")) {
            try store.supersede(
                sourceIDs: [question.id],
                with: ["missing"],
                reason: "Replacement unavailable"
            )
        }
        _ = try store.answer(id: question.id, answer: "Already answered")
        var replacement = item(id: "replacement", createdAt: 20)
        replacement.kind = .question
        replacement.questionStatus = .pending
        try store.save(replacement)
        #expect(throws: QueueOperationError.questionAlreadyResolved(question.id)) {
            try store.supersede(
                sourceIDs: [question.id],
                with: [replacement.id],
                reason: "Too late"
            )
        }
    }

    @Test @MainActor
    func automaticPlaybackRecordsConservativeUnattendedEvidence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        try store.save(item(id: "automatic", createdAt: 10, outputFile: audio.path))
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false },
            idleSeconds: { 120 }
        )
        defer { controller.shutdown() }

        controller.start()
        controller.audioPlayerDidFinishPlaying(AVAudioPlayer(), successfully: true)

        let persisted = try #require(try store.loadItems().first)
        #expect(persisted.status == .played)
        #expect(persisted.playbackInitiator == .automatic)
        #expect(persisted.engagement == .unattendedLikely)
        #expect(persisted.userActivity?.activityObserved == false)
        #expect(persisted.userActivity?.directInteraction == false)
    }

    @Test @MainActor
    func hoverDeferralHoldsAndThenContinuesThePlaybackQueue() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        let first = item(id: "first", createdAt: 10, outputFile: audio.path)
        let second = item(id: "second", createdAt: 20, outputFile: audio.path)
        try store.save(first)
        try store.save(second)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false }
        )
        defer { controller.shutdown() }

        controller.setAutomaticQueueAdvanceDeferred(true)
        controller.start()
        #expect(controller.currentItem == nil)
        #expect(controller.nextQueuedItem?.id == first.id)

        controller.setAutomaticQueueAdvanceDeferred(false)
        #expect(controller.currentItem?.id == first.id)

        controller.setAutomaticQueueAdvanceDeferred(true)
        controller.audioPlayerDidFinishPlaying(AVAudioPlayer(), successfully: true)
        #expect(controller.currentItem == nil)
        #expect(controller.nextQueuedItem?.id == second.id)

        controller.setAutomaticQueueAdvanceDeferred(false)
        #expect(controller.currentItem?.id == second.id)
    }

    @Test @MainActor
    func explicitPlaybackRecordsDirectInteractionEvidence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        let queued = item(id: "direct", createdAt: 10, outputFile: audio.path)
        try store.save(queued)
        try store.setGlobalPlaybackPaused(true)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false },
            idleSeconds: { 120 }
        )
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(queued)

        let persisted = try #require(try store.loadItems().first)
        #expect(persisted.playbackInitiator == .direct)
        #expect(persisted.engagement == .directInteraction)
        #expect(persisted.userActivity?.directInteraction == true)
    }

    @Test @MainActor
    func replacingPlaybackDoesNotClaimInterruptedItemFullyPlayed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("silence.wav")
        try writeSilentAudio(to: audio)
        let store = QueueStore(stateDirectory: directory)
        let first = item(id: "first", createdAt: 10, outputFile: audio.path)
        let second = item(id: "second", createdAt: 20, outputFile: audio.path)
        try store.save(first)
        try store.save(second)
        try store.setGlobalPlaybackPaused(true)
        let controller = PlaybackController(
            store: store,
            mediaController: disabledMediaController(stateDirectory: directory),
            outputIsMuted: { false },
            idleSeconds: { 120 }
        )
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(first)
        controller.playNow(second)

        let interrupted = try #require(try store.loadItems().first { $0.id == first.id })
        #expect(interrupted.status == .interrupted)
        #expect(interrupted.unheard)
        #expect(interrupted.engagement == .directInteraction)
        #expect(interrupted.status.isRecent)
    }

    @Test
    func sharedQueueReadsWaitForExclusiveOperation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        try store.save(item(id: "one", createdAt: 10))
        let descriptor = open(store.operationsLockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX) == 0)

        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            _ = try? store.loadItems()
            completed.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + 0.05) == .timedOut)

        #expect(flock(descriptor, LOCK_UN) == 0)
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func submitsBundleWithMixedAnsweredAndSkippedQuestionsOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "bundle")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(questionID: "q-01", answer: "Use the shared model"),
                TTSQuestionDraft(questionID: "q-02", answer: "   "),
            ],
            actor: "test-agent",
            now: 40
        )

        #expect(submitted.questionStatus == .answered)
        #expect(submitted.questions?[0].status == .answered)
        #expect(submitted.questions?[0].response?.answer == "Use the shared model")
        #expect(submitted.questions?[0].response?.answeredAt == 40)
        #expect(submitted.questions?[1].status == .skipped)
        #expect(submitted.questions?[1].response == nil)
        let operations = try FileManager.default.contentsOfDirectory(
            at: store.operationsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(operations.count == 1)
        let operation = try JSONDecoder().decode(
            QueueOperation.self,
            from: Data(contentsOf: operations[0])
        )
        #expect(operation.kind == .answer)
        #expect(operation.sourceIDs == [bundle.id])
        #expect(operation.actor == "test-agent")
        #expect(throws: QueueOperationError.questionAlreadyResolved(bundle.id)) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(questionID: "q-01", answer: "Again"),
                    TTSQuestionDraft(questionID: "q-02", answer: "Again"),
                ]
            )
        }
    }

    @Test
    func allBlankBundleDraftsResolveAsSkipped() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "all-skipped")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(questionID: "q-01", answer: ""),
                TTSQuestionDraft(questionID: "q-02", answer: "\n  "),
            ]
        )

        #expect(submitted.questionStatus == .answered)
        #expect(submitted.questions?.allSatisfy { $0.status == .skipped } == true)
        #expect(submitted.questions?.allSatisfy { $0.response == nil } == true)
    }

    @Test
    func bundleSuggestionUsesStableIDAndTracksEditedAnswer() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "suggested")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "Use the shared model after validation",
                    suggestionID: "q-01-s-01",
                    selectedSuggestions: [TTSQuestionDraftSuggestion(
                        id: "q-01-s-01",
                        title: "Use the shared model after validation",
                        description: "Keep ownership shared after the validation pass."
                    )]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: "No change"),
            ]
        )

        let response = try #require(submitted.questions?[0].response)
        #expect(response.suggestionID == "q-01-s-01")
        #expect(response.suggestionIDs == ["q-01-s-01"])
        #expect(response.suggestionIndex == 0)
        #expect(response.modified)
        #expect(response.answer == "Use the shared model after validation")
        #expect(response.selectedSuggestions == [TTSSelectedSuggestion(
            id: "q-01-s-01",
            title: "Use the shared model after validation",
            description: "Keep ownership shared after the validation pass.",
            modified: true
        )])
    }

    @Test
    func descriptionOnlySuggestionEditIsReturnedAndMarkedModified() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "description-edit")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "Use the shared model",
                    suggestionID: "q-01-s-01",
                    selectedSuggestions: [TTSQuestionDraftSuggestion(
                        id: "q-01-s-01",
                        title: "Use the shared model",
                        description: "Keep one source of truth and document its owner."
                    )]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: ""),
            ]
        )

        let response = try #require(submitted.questions?[0].response)
        #expect(response.modified)
        #expect(response.selectedSuggestions?.first?.title == "Use the shared model")
        #expect(
            response.selectedSuggestions?.first?.description
                == "Keep one source of truth and document its owner."
        )
    }

    @Test
    func suggestionDetailOrderMismatchIsRejectedAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var bundle = bundleItem(id: "detail-mismatch")
        bundle.questions?[0].type = .multipleChoice
        bundle.questions?[0].suggestions?.append(
            TTSSuggestion(title: "Split the model", id: "q-01-s-02")
        )
        try store.save(bundle)

        #expect(throws: QueueOperationError.invalidBundleDrafts(
            "selected suggestion details must match selected ID order for question q-01"
        )) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(
                        questionID: "q-01",
                        answer: "Use the shared model, Split the model",
                        suggestionIDs: ["q-01-s-01", "q-01-s-02"],
                        selectedSuggestions: [
                            TTSQuestionDraftSuggestion(id: "q-01-s-02", title: "Split the model"),
                            TTSQuestionDraftSuggestion(id: "q-01-s-01", title: "Use the shared model"),
                        ]
                    ),
                    TTSQuestionDraft(questionID: "q-02", answer: ""),
                ]
            )
        }
        #expect(try store.item(id: bundle.id)?.questionStatus == .pending)
    }

    @Test
    func multipleChoicePreservesOrderedStableSuggestionIDs() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var bundle = bundleItem(id: "multiple")
        bundle.questions?[0].type = .multipleChoice
        bundle.questions?[0].suggestions?.append(
            TTSSuggestion(
                title: "Split the model",
                description: "Use distinct ownership.",
                id: "q-01-s-02"
            )
        )
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "Split the model, Use the shared model",
                    suggestionIDs: ["q-01-s-02", "q-01-s-01"],
                    selectedSuggestions: [
                        TTSQuestionDraftSuggestion(
                            id: "q-01-s-02",
                            title: "Split the model",
                            description: "Use distinct ownership."
                        ),
                        TTSQuestionDraftSuggestion(
                            id: "q-01-s-01",
                            title: "Use the shared model",
                            description: "Keep one source of truth."
                        ),
                    ]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: ""),
            ]
        )

        let response = try #require(submitted.questions?[0].response)
        #expect(response.answer == "Split the model, Use the shared model")
        #expect(response.suggestionIDs == ["q-01-s-02", "q-01-s-01"])
        #expect(response.suggestionID == nil)
        #expect(response.suggestionIndex == nil)
        #expect(!response.modified)
        #expect(response.selectedSuggestions?.map(\.id) == ["q-01-s-02", "q-01-s-01"])
    }

    @Test
    func singleChoiceRejectsMultipleSelectedSuggestionIDsAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var bundle = bundleItem(id: "single")
        bundle.questions?[0].suggestions?.append(
            TTSSuggestion(
                title: "Split the model",
                description: "Use distinct ownership.",
                id: "q-01-s-02"
            )
        )
        try store.save(bundle)

        #expect(throws: QueueOperationError.invalidBundleDrafts(
            "question q-01 accepts only one suggestion"
        )) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(
                        questionID: "q-01",
                        answer: "Use both",
                        suggestionIDs: ["q-01-s-01", "q-01-s-02"]
                    ),
                    TTSQuestionDraft(questionID: "q-02", answer: ""),
                ]
            )
        }
        let persisted = try #require(try store.item(id: bundle.id))
        #expect(persisted.questionStatus == .pending)
        #expect(persisted.questions?.allSatisfy { $0.status == .pending } == true)
    }

    @Test
    func questionTypeDefaultsToSingleChoiceWhenLegacyJSONOmitsIt() throws {
        let question = try JSONDecoder().decode(
            TTSQuestion.self,
            from: Data(#"{"id":"q-01","title":"Legacy question","status":"pending"}"#.utf8)
        )

        #expect(question.type == .singleChoice)
    }

    @Test
    func responseRoundTripsPluralSuggestionIDsAlongsideLegacyFields() throws {
        let original = TTSResponse(
            answer: "First, Second",
            suggestionIndex: nil,
            modified: false,
            answeredAt: 50,
            interaction: "suggestion",
            suggestionID: nil,
            suggestionIDs: ["first", "second"],
            selectedSuggestions: [
                TTSSelectedSuggestion(
                    id: "first",
                    title: "First",
                    description: "First detail",
                    modified: false
                ),
                TTSSelectedSuggestion(
                    id: "second",
                    title: "Second revised",
                    description: nil,
                    modified: true
                ),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["suggestion_ids"] as? [String] == ["first", "second"])
        #expect(object["suggestion_id"] == nil)
        #expect((object["selected_suggestions"] as? [[String: Any]])?.count == 2)
        let decoded = try JSONDecoder().decode(TTSResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func copiesAnswerAttachmentsIntoCollisionSafeDurableAssets() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = directory.appendingPathComponent("originals", isDirectory: true)
        let firstDirectory = originals.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = originals.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("evidence.txt")
        let second = secondDirectory.appendingPathComponent("evidence.txt")
        try Data("first evidence".utf8).write(to: first)
        try Data("second evidence".utf8).write(to: second)
        let store = QueueStore(stateDirectory: directory.appendingPathComponent("state", isDirectory: true))
        var bundle = bundleItem(id: "attachments")
        bundle.assetDirectory = directory.appendingPathComponent("durable", isDirectory: true).path
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "",
                    attachmentURLs: [first, second]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: ""),
            ]
        )
        let attachments = try #require(submitted.questions?[0].response?.attachments)
        #expect(submitted.questions?[0].status == .answered)
        #expect(submitted.questions?[0].response?.answer == "")
        #expect(attachments.count == 2)
        #expect(Set(attachments.map(\.sourceFile)).count == 2)
        #expect(attachments.map(\.label) == ["evidence.txt", "evidence.txt"])

        try FileManager.default.removeItem(at: originals)
        let persisted = try #require(try store.item(id: bundle.id))
        let durable = try #require(persisted.questions?[0].response?.attachments)
        #expect(durable.allSatisfy { FileManager.default.fileExists(atPath: $0.sourceFile) })
        #expect(
            Set(try durable.map { try String(contentsOfFile: $0.sourceFile, encoding: .utf8) })
                == Set(["first evidence", "second evidence"])
        )
    }

    @Test
    func invalidBundleDraftLeavesStateAndAssetsUntouched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("answer.txt")
        try Data("answer".utf8).write(to: source)
        let store = QueueStore(stateDirectory: directory.appendingPathComponent("state", isDirectory: true))
        var bundle = bundleItem(id: "atomic")
        bundle.assetDirectory = directory.appendingPathComponent("durable", isDirectory: true).path
        try store.save(bundle)

        #expect(throws: QueueOperationError.invalidSuggestionID("missing")) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(
                        questionID: "q-01",
                        answer: "Valid so far",
                        attachmentURLs: [source]
                    ),
                    TTSQuestionDraft(
                        questionID: "q-02",
                        answer: "Invalid",
                        suggestionID: "missing"
                    ),
                ]
            )
        }

        let persisted = try #require(try store.item(id: bundle.id))
        #expect(persisted.questionStatus == .pending)
        #expect(persisted.questions?.allSatisfy { $0.status == .pending && $0.response == nil } == true)
        #expect(
            (try FileManager.default.contentsOfDirectory(
                at: store.operationsDirectory,
                includingPropertiesForKeys: nil
            )).isEmpty
        )
        #expect(!FileManager.default.fileExists(atPath: bundle.assetDirectory!))
    }

    @Test
    func decodesLegacySuggestionResponseAndAttachmentWithoutNewFields() throws {
        let suggestion = try JSONDecoder().decode(
            TTSSuggestion.self,
            from: Data(#"{"title":"Legacy","description":"Old pair"}"#.utf8)
        )
        let response = try JSONDecoder().decode(
            TTSResponse.self,
            from: Data(#"{"answer":"Yes","suggestion_index":0,"modified":false,"answered_at":12,"interaction":"suggestion"}"#.utf8)
        )
        let attachment = try JSONDecoder().decode(
            TTSAttachment.self,
            from: Data(#"{"id":"a","label":"A","kind":"file","status":"ready","source_file":"/tmp/a"}"#.utf8)
        )

        #expect(suggestion.id == nil)
        #expect(suggestion.attachments == nil)
        #expect(response.suggestionIndex == 0)
        #expect(response.suggestionID == nil)
        #expect(response.attachments == nil)
        #expect(attachment.description == nil)
    }

    @Test
    func stalePlaybackSaveCannotClobberTerminalBundleResponses() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var stale = bundleItem(id: "concurrent")
        try store.save(stale)
        _ = try store.submitBundle(
            id: stale.id,
            drafts: [
                TTSQuestionDraft(questionID: "q-01", answer: "Durable first"),
                TTSQuestionDraft(questionID: "q-02", answer: "Durable second"),
            ]
        )

        stale.status = .played
        try store.save(stale)

        let persisted = try #require(try store.item(id: stale.id))
        #expect(persisted.status == .played)
        #expect(persisted.questionStatus == .answered)
        #expect(persisted.questions?.map { $0.response?.answer } == ["Durable first", "Durable second"])
        #expect(persisted.questions?.allSatisfy { $0.status == .answered } == true)
    }

    private func item(
        id: String,
        createdAt: Int64,
        outputFile: String = "/tmp/speech.mp3"
    ) -> TTSItem {
        TTSItem(
            id: id,
            text: "A useful spoken update",
            subject: "A useful spoken update subject",
            agentName: "clay-river-860",
            harness: "codex",
            sessionID: "thread-123",
            workspace: "/tmp/skills",
            voice: "af_bella",
            outputFile: outputFile,
            status: .queued,
            createdAt: createdAt,
            startedAt: nil,
            completedAt: nil,
            duration: nil,
            error: nil
        )
    }

    private func bundleItem(id: String) -> TTSItem {
        var value = item(id: id, createdAt: 10)
        value.kind = .question
        value.questionStatus = .pending
        value.questionsPreamble = "There are two details to settle before implementation."
        value.questions = [
            TTSQuestion(
                id: "q-01",
                title: "Which model?",
                shortTitle: "Model",
                suggestions: [
                    TTSSuggestion(
                        title: "Use the shared model",
                        description: "Keep one source of truth.",
                        id: "q-01-s-01"
                    ),
                ]
            ),
            TTSQuestion(
                id: "q-02",
                title: "Any caveats?",
                shortTitle: "Caveats",
                suggestions: [
                    TTSSuggestion(
                        title: "No change",
                        description: "Keep the current behavior.",
                        id: "q-02-s-01"
                    ),
                ]
            ),
        ]
        return value
    }

    @MainActor
    private func disabledMediaController(stateDirectory: URL) -> MediaController {
        let preferencesStore = PlayerPreferencesStore(stateDirectory: stateDirectory)
        preferencesStore.setPausesMedia(false)
        return MediaController(preferencesStore: preferencesStore)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-menu-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeSilentAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func timing(_ word: String, _ start: Double, _ end: Double) -> TTSWordTiming {
        TTSWordTiming(word: word, startTime: start, endTime: end)
    }

    private func attachment() -> TTSAttachment {
        TTSAttachment(
            id: "why",
            label: "Why this matters",
            kind: .narratedText,
            status: .ready,
            sourceFile: "/tmp/why.md",
            text: "# Why this matters\n\nUseful detail.",
            audioFile: "/tmp/why.mp3",
            wordTimings: [timing("Useful", 0, 0.4)],
            error: nil
        )
    }
}

private final class TestITermSessionScripting: ITermSessionScripting {
    var existingSessionIDs = Set<String>()
    var selectedSessionIDs = [String]()

    func sessionExists(uniqueID: String) -> Bool {
        existingSessionIDs.contains(uniqueID)
    }

    func selectSession(uniqueID: String) -> Bool {
        selectedSessionIDs.append(uniqueID)
        return existingSessionIDs.contains(uniqueID)
    }
}
