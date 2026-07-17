import AppKit
import Foundation

@MainActor
extension PlaybackController {
    func replay(_ item: TTSItem, startingAt time: TimeInterval? = nil) {
        guard FileManager.default.fileExists(atPath: item.outputFile) else { return }
        do {
            let offset = time.map { max(0, $0) }
            try store.save(item.requeuedForReplay(startingAt: offset))
            refresh()
        } catch {
            NSLog("Unable to queue replay: %@", error.localizedDescription)
        }
    }

    func playNow(_ item: TTSItem) {
        guard FileManager.default.fileExists(atPath: item.outputFile) else {
            if item.status == .queued {
                fail(item, message: "Audio file is no longer available.")
            }
            return
        }
        guard clearGlobalPauseForExplicitPlayback() else { return }

        if currentItem?.id == item.id, let player {
            if isPlaybackBlocked {
                automaticallyPausedItemID = item.id
                return
            }
            resumeCurrentItem(player)
            return
        }

        if currentItem != nil {
            finishCurrentForReplacement()
        }
        if visibleAskQueueHoldID != item.id {
            visibleAskQueueHoldID = nil
        }

        let requested = item.status == .queued
            ? item
            : item.requeuedForReplay(startingAt: item.playbackOffset)
        do {
            try store.save(requested)
            replaceItem(requested)
            play(requested, initiator: .direct)
        } catch {
            NSLog("Unable to play selected TTS item: %@", error.localizedDescription)
        }
    }

    func isRetrying(_ item: TTSItem) -> Bool {
        retryingItemIDs.contains(item.id)
    }

    func retryGeneration(_ item: TTSItem) {
        guard item.status == .failed, !isRetrying(item) else { return }
        guard let command = retryCommand(for: item) else {
            recordRetryFailure(for: item, message: "The TTS command is no longer available.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        var arguments = ["--message", item.text]
        if let subject = item.subject, !subject.isEmpty {
            arguments += ["--subject", subject]
        }
        if let summary = item.previewSummary {
            arguments += ["--summary", summary]
        }
        if let agentName = item.agentName, !agentName.isEmpty {
            arguments += ["--agent-name", agentName]
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["TTS_STATE_DIR"] = store.stateDirectory.path
        environment["TTS_INTERNAL_RETRY"] = "1"
        environment["TTS_INTERNAL_VOICE_ID"] = item.voice
        if let workspace = item.workspace, !workspace.isEmpty {
            environment["TTS_WORKSPACE"] = workspace
        }
        if let sessionID = item.sessionID, !sessionID.isEmpty {
            environment["TTS_SESSION_ID"] = sessionID
            environment["TTS_SESSION_STORAGE_ID"] = sessionID
        }
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.retryingItemIDs.remove(item.id)
                self?.refresh()
            }
        }

        do {
            retryingItemIDs.insert(item.id)
            try process.run()
        } catch {
            retryingItemIDs.remove(item.id)
            recordRetryFailure(for: item, message: "Unable to start retry: \(error.localizedDescription)")
        }
    }

    func reveal(_ item: TTSItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.outputFile)])
    }

    func setArchived(_ archived: Bool, for item: TTSItem) {
        guard !item.isAttachmentPlayback else { return }
        do {
            let updated = try store.setArchived(archived, id: item.id, actor: "tts-menu")
            replaceItem(updated)
            if archived {
                clearVisibleAskQueueHold(for: item.id)
            }
        } catch {
            NSLog("Unable to update TTS archive state: %@", error.localizedDescription)
        }
    }

    func answer(_ item: TTSItem, text: String, suggestionIndex: Int? = nil) {
        do {
            let updated = try store.answer(
                id: item.id,
                answer: text,
                suggestionIndex: suggestionIndex,
                interaction: suggestionIndex == nil ? "freeform" : "suggestion"
            )
            replaceItem(updated)
            clearVisibleAskQueueHold(for: item.id)
        } catch {
            NSLog("Unable to answer TTS question: %@", error.localizedDescription)
            refresh()
        }
    }

    func skipQuestion(_ item: TTSItem) {
        do {
            let updated = try store.skipQuestion(id: item.id, actor: "tts-menu")
            replaceItem(updated)
            clearVisibleAskQueueHold(for: item.id)
        } catch {
            NSLog("Unable to skip TTS question: %@", error.localizedDescription)
            refresh()
        }
    }

    func submitBundle(_ item: TTSItem, drafts: [TTSQuestionDraft]) {
        do {
            let updated = try store.submitBundle(
                id: item.id,
                drafts: drafts,
                actor: "tts-menu"
            )
            replaceItem(updated)
            clearVisibleAskQueueHold(for: item.id)
        } catch {
            NSLog("Unable to submit TTS question bundle: %@", error.localizedDescription)
            refresh()
        }
    }
}
