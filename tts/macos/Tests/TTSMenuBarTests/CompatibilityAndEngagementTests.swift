import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
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
        try store.admitPlayback(of: "automatic", requestedAtNanoseconds: 10)
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

}
