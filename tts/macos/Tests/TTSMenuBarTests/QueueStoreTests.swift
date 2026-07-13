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
        let store = HUDPreferencesStore(stateDirectory: directory)

        #expect(store.preferences == HUDPreferences())
        store.setPlayerVisible(false)
        store.setMiniPlayer(true)
        store.setOrigin(CGPoint(x: -820, y: 146))
        store.setExpandedSize(CGSize(width: 680, height: 560))

        let reloaded = HUDPreferencesStore(stateDirectory: directory)
        #expect(!reloaded.preferences.isPlayerVisible)
        #expect(reloaded.preferences.isMiniPlayer)
        #expect(reloaded.preferences.origin == CGPoint(x: -820, y: 146))
        #expect(reloaded.preferences.expandedSize == CGSize(width: 680, height: 560))
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
            mediaController: MediaController(environment: ["TTS_MEDIA_CONTROL": "0"]),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }

        controller.start()

        #expect(controller.isSystemOutputMuted)
        #expect(controller.currentItem == nil)
        #expect(try store.loadItems().map(\.status) == [.queued])
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
            mediaController: MediaController(environment: ["TTS_MEDIA_CONTROL": "0"]),
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
    func explicitRecentSelectionCreatesPlaybackCopyAndClearsPauseAll() throws {
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
            mediaController: MediaController(environment: ["TTS_MEDIA_CONTROL": "0"]),
            outputIsMuted: { true }
        )
        defer { controller.shutdown() }
        controller.start()

        controller.playNow(recent)

        let items = try store.loadItems()
        #expect(!controller.isGloballyPaused)
        #expect(items.contains { $0.id == recent.id && $0.status == .played })
        #expect(items.contains { $0.id.hasPrefix("replay-") && $0.status == .queued })
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
    func replayCopiesMetadataAndReturnsToQueue() {
        var original = item(id: "done", createdAt: 10)
        original.status = .played
        original.startedAt = 11
        original.completedAt = 12
        original.wordTimings = [timing("A", 0, 0.2)]
        original.attachments = [attachment()]
        original.assetDirectory = "/tmp/brief"

        let replay = original.replayCopy(now: 20)

        #expect(replay.id.hasPrefix("replay-"))
        #expect(replay.text == original.text)
        #expect(replay.subject == original.subject)
        #expect(replay.agentName == original.agentName)
        #expect(replay.sessionID == original.sessionID)
        #expect(replay.status == .queued)
        #expect(replay.createdAt == 20)
        #expect(replay.startedAt == nil)
        #expect(replay.completedAt == nil)
        #expect(replay.playbackOffset == nil)
        #expect(replay.wordTimings == original.wordTimings)
        #expect(replay.attachments == original.attachments)
        #expect(replay.assetDirectory == original.assetDirectory)
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
            mediaController: MediaController(environment: ["TTS_MEDIA_CONTROL": "0"]),
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
            mediaController: MediaController(environment: ["TTS_MEDIA_CONTROL": "0"]),
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

        let replay = original.replayCopy(now: 20, startingAt: 42.5)

        #expect(replay.status == .queued)
        #expect(replay.playbackOffset == 42.5)
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

    @MainActor
    @Test
    func speakingPanelCannotTakeWindowFocus() {
        let panel = PassiveHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.ignoresMouseEvents)

        let hostingView = FirstMouseHostingView(rootView: EmptyView())
        #expect(hostingView.acceptsFirstMouse(for: nil))
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

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TTSItem.self, from: legacyData)

        #expect(decoded.subject == nil)
        #expect(decoded.playbackOffset == nil)
        #expect(decoded.wordTimings == nil)
        #expect(decoded.attachments == nil)
        #expect(decoded.assetDirectory == nil)
        #expect(!decoded.isAttachmentPlayback)
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-menu-tests-\(UUID().uuidString)", isDirectory: true)
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
