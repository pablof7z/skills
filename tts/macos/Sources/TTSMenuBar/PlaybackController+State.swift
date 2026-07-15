import Foundation

@MainActor
extension PlaybackController {
    func finishCurrent(
        success: Bool,
        error: String?,
        terminalStatus: PlaybackStatus? = nil
    ) {
        guard var item = currentItem else { return }
        let parentReturn = success
            ? item.parentItemID.flatMap { parentID in
                item.returnToPlaybackOffset.map { (parentID, $0) }
            }
            : nil
        playbackStartTask?.cancel()
        playbackStartTask = nil
        item.status = terminalStatus ?? (success ? .played : .failed)
        item.completedAt = Int64(Date().timeIntervalSince1970)
        item.duration = player?.duration ?? item.duration
        item.error = error
        finalizeEngagement(on: &item)
        if item.status == .played, !item.isAttachmentPlayback {
            item.isUnheard = false
        } else if item.status == .interrupted, !item.isAttachmentPlayback {
            item.isUnheard = true
        }
        try? store.save(item)

        player = nil
        isAudioPlaying = false
        currentItemID = nil
        automaticallyPausedItemID = nil
        currentTime = 0
        duration = 0
        replaceItem(item)

        if let (parentID, offset) = parentReturn,
           let parent = (try? store.loadItems())?.first(where: { $0.id == parentID }) {
            let resumed = parent.requeuedForReplay(startingAt: offset)
            do {
                try store.save(resumed)
                replaceItem(resumed)
                if isPlaybackBlocked {
                    refresh()
                } else {
                    play(resumed)
                }
                return
            } catch {
                NSLog("Unable to resume parent TTS item: %@", error.localizedDescription)
            }
        }

        let hasQueuedItem = (try? store.loadItems().contains { $0.status == .queued }) ?? false
        if hasQueuedItem {
            refresh()
        } else {
            mediaController.resumePausedApps(after: mediaController.mediaResumeDelay)
        }
    }

    func finishCurrentForReplacement() {
        guard var item = currentItem else { return }
        playbackStartTask?.cancel()
        playbackStartTask = nil
        player?.stop()
        markDirectInteraction(on: &item)
        item.status = .interrupted
        if !item.isAttachmentPlayback {
            item.isUnheard = true
        }
        item.completedAt = Int64(Date().timeIntervalSince1970)
        item.duration = player?.duration ?? item.duration
        item.error = nil
        finalizeEngagement(on: &item)
        try? store.save(item)

        player = nil
        isAudioPlaying = false
        currentItemID = nil
        automaticallyPausedItemID = nil
        currentTime = 0
        duration = 0
        replaceItem(item)
    }

    func fail(_ item: TTSItem, message: String) {
        var failed = item
        failed.status = .failed
        failed.completedAt = Int64(Date().timeIntervalSince1970)
        failed.error = message
        try? store.save(failed)
        replaceItem(failed)
    }

    func retryCommand(for item: TTSItem) -> String? {
        let candidates = [
            item.retryCommand,
            NSString(string: "~/.agents/skills/tts/scripts/tts").expandingTildeInPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func recordRetryFailure(for item: TTSItem, message: String) {
        var failed = item
        failed.error = message
        failed.completedAt = Int64(Date().timeIntervalSince1970)
        try? store.save(failed)
        replaceItem(failed)
    }

    func replaceItem(_ item: TTSItem) {
        historyRevision &+= 1
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort {
                if $0.createdAt == $1.createdAt {
                    return $0.id < $1.id
                }
                return $0.createdAt < $1.createdAt
            }
        }
        historyTimestampClock.update(items: items, at: Date(), reschedule: true)
    }

    func recordDirectInteraction() {
        guard var item = currentItem else { return }
        markDirectInteraction(on: &item)
        try? store.save(item)
        replaceItem(item)
    }

    func markDirectInteraction(on item: inout TTSItem) {
        let now = Int64(Date().timeIntervalSince1970)
        var activity = item.userActivity ?? TTSUserActivity(
            idleSecondsAtStart: nil,
            idleSecondsAtEnd: nil,
            activityObserved: false,
            directInteraction: false,
            lastInteractionAt: nil,
            recordedAt: now
        )
        activity.directInteraction = true
        activity.activityObserved = true
        activity.lastInteractionAt = now
        activity.recordedAt = now
        item.userActivity = activity
        item.engagement = .directInteraction
    }

    private func finalizeEngagement(on item: inout TTSItem) {
        let now = Int64(Date().timeIntervalSince1970)
        let idleAtEnd = idleSeconds()
        var activity = item.userActivity ?? TTSUserActivity(
            idleSecondsAtStart: nil,
            idleSecondsAtEnd: nil,
            activityObserved: false,
            directInteraction: false,
            lastInteractionAt: nil,
            recordedAt: now
        )
        activity.idleSecondsAtEnd = idleAtEnd
        let playbackElapsed = item.startedAt.map { max(0, TimeInterval(now - $0)) } ?? 0
        if idleAtEnd < playbackElapsed {
            activity.activityObserved = true
        }
        activity.recordedAt = now
        item.userActivity = activity
        if activity.directInteraction || item.playbackInitiator == .direct {
            item.engagement = .directInteraction
        } else if activity.activityObserved {
            item.engagement = .presentUnconfirmed
        } else if item.playbackInitiator == .automatic {
            item.engagement = .unattendedLikely
        } else {
            item.engagement = .unknown
        }
    }
}
