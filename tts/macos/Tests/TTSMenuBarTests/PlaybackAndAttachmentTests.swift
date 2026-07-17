import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
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
    func keepsOptionalSummaryForPreview() {
        var value = item(id: "summary", createdAt: 10)
        value.summary = "Queue ownership now has one clear source of truth."

        #expect(value.previewSummary == "Queue ownership now has one clear source of truth.")
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

}
