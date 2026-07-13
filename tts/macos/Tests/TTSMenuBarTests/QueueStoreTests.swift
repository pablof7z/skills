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
    func replayCopiesMetadataAndReturnsToQueue() {
        var original = item(id: "done", createdAt: 10)
        original.status = .played
        original.startedAt = 11
        original.completedAt = 12

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
    func buildsNowSpeakingContextFromAgentAndFullWorkspacePath() {
        var value = item(id: "hud", createdAt: 10)
        value.subject = "The passive speaking cue is ready"
        value.agentName = "river-codex"
        value.workspace = "/Users/pablofernandez/Work/skills"

        #expect(value.nowSpeakingTitle == "The passive speaking cue is ready")
        #expect(value.workspacePath == "/Users/pablofernandez/Work/skills")
        #expect(value.nowSpeakingContext == "river-codex · /Users/pablofernandez/Work/skills")
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
        #expect(
            WorkspaceAccent.paletteIndex(forWorkspacePath: nested.path)
                == WorkspaceAccent.paletteIndex(forWorkspacePath: project.path)
        )
    }

    @Test
    func recognizesGitWorktreeMarkerFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let nested = worktree.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/repo/.git/worktrees/feature\n".utf8).write(
            to: worktree.appendingPathComponent(".git")
        )

        #expect(WorkspaceAccent.projectLabel(forWorkspacePath: nested.path) == "feature-worktree")
    }

    @Test
    func fallsBackToWorkspaceBasenameOutsideGit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("standalone-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let index = WorkspaceAccent.paletteIndex(forWorkspacePath: workspace.path)

        #expect(WorkspaceAccent.projectLabel(forWorkspacePath: workspace.path) == "standalone-workspace")
        #expect(index >= 0 && index < WorkspaceAccent.count)
        #expect(index == WorkspaceAccent.paletteIndex(forWorkspacePath: workspace.path))
    }

    @Test
    func mapsTranscriptWordsToPlaybackTime() {
        #expect(TranscriptTiming.activeWordIndex(currentTime: 0, duration: 100, wordCount: 10) == 0)
        #expect(TranscriptTiming.activeWordIndex(currentTime: 52, duration: 100, wordCount: 10) == 5)
        #expect(TranscriptTiming.activeWordIndex(currentTime: 100, duration: 100, wordCount: 10) == 9)
        #expect(TranscriptTiming.time(forWordAt: 5, wordCount: 10, duration: 100) == 50)
        #expect(TranscriptTiming.time(forWordAt: 99, wordCount: 10, duration: 100) == 90)
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
    func decodesExistingQueueItemsWithoutSubject() throws {
        let data = try JSONEncoder().encode(item(id: "legacy", createdAt: 10))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "subject")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TTSItem.self, from: legacyData)

        #expect(decoded.subject == nil)
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
}
