import AVFAudio
import Foundation

@MainActor
extension PlaybackController {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishCurrent(success: flag, error: flag ? nil : "Playback stopped before completion.")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishCurrent(success: false, error: error?.localizedDescription ?? "Unable to decode audio.")
    }

    func refresh() {
        do {
            let now = Date()
            let persistedPause = store.isGlobalPlaybackPaused()
            if persistedPause != isGloballyPaused {
                isGloballyPaused = persistedPause
                updatePlaybackForBlockingState()
            }
            let outputMuted = outputIsMuted()
            if outputMuted != isSystemOutputMuted {
                isSystemOutputMuted = outputMuted
                updatePlaybackForBlockingState()
            }
            var itemsChangeToken = try store.itemsChangeToken()
            let shouldReloadItems = itemsChangeToken != lastItemsChangeToken
            var loaded = shouldReloadItems ? try store.loadItems() : items
            let generatingIDs = loaded.filter { $0.status == .generating }.map(\.id)
            if !generatingIDs.isEmpty,
               try store.recoverOrphanedGeneratingItems(generatingIDs) > 0 {
                itemsChangeToken = try store.itemsChangeToken()
                loaded = try store.loadItems()
            }
            if let heldID = visibleAskQueueHoldID,
               loaded.first(where: { $0.id == heldID })?.isPendingQuestion != true {
                visibleAskQueueHoldID = nil
            }
            lastItemsChangeToken = itemsChangeToken
            let historyChanged = shouldReloadItems && loaded != items
            if historyChanged {
                historyRevision &+= 1
                items = loaded
            }
            if loaded.contains(where: { $0.status == .generating && !$0.isAttachmentPlayback }) {
                generationProgressNow = now
            }
            historyTimestampClock.update(items: loaded, at: now, reschedule: historyChanged)
            if let player {
                let nextTime = player.currentTime
                let nextDuration = player.duration
                if abs(currentTime - nextTime) > 0.001 {
                    currentTime = nextTime
                }
                if abs(duration - nextDuration) > 0.001 {
                    duration = nextDuration
                }
                if currentItem?.status == .paused,
                   automaticallyPausedItemID == nil,
                   !isPlaybackBlocked,
                   let next = automaticPlaybackCandidate(in: loaded)
                {
                    parkPausedCurrentForIncomingPlayback()
                    playAutomaticCandidate(next)
                }
            } else if !isPlaybackBlocked {
                if let next = automaticPlaybackCandidate(in: loaded) {
                    playAutomaticCandidate(next)
                }
            }
        } catch {
            NSLog("Unable to refresh TTS queue: %@", error.localizedDescription)
        }
    }

    static func nextQueuedItem(in items: [TTSItem]) -> TTSItem? {
        QueuePlaybackPolicy.nextQueuedItem(in: items)
    }

    func automaticPlaybackCandidate(in items: [TTSItem]) -> TTSItem? {
        if let heldID = visibleAskQueueHoldID {
            guard let held = items.first(where: { $0.id == heldID && $0.status == .queued }) else {
                return nil
            }
            guard manualQueuePauseBarrier?.allows(held) != false else { return nil }
            return held
        }
        if let manualQueuePauseBarrier {
            return manualQueuePauseBarrier.nextArrival(in: items)
        }
        return QueuePlaybackPolicy.nextQueuedItem(in: items)
    }

    func playAutomaticCandidate(_ item: TTSItem) {
        manualQueuePauseBarrier?.recordStarted(item)
        play(item)
    }

    func play(
        _ queuedItem: TTSItem,
        initiator: TTSPlaybackInitiator = .automatic
    ) {
        let opensPaused = isPlaybackBlocked && initiator == .direct
        guard !isPlaybackBlocked || opensPaused else { return }
        guard FileManager.default.fileExists(atPath: queuedItem.outputFile) else {
            fail(queuedItem, message: "Audio file is no longer available.")
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: queuedItem.outputFile))
            audioPlayer.delegate = self
            audioPlayer.enableRate = true
            let preferredRate = playbackRateStore.rate(for: queuedItem.voice)
            audioPlayer.rate = preferredRate
            audioPlayer.prepareToPlay()

            if let offset = queuedItem.playbackOffset {
                audioPlayer.currentTime = min(max(0, offset), audioPlayer.duration)
            }

            var item = queuedItem
            item.status = opensPaused ? .paused : .playing
            item.startedAt = Int64(Date().timeIntervalSince1970)
            item.completedAt = nil
            item.duration = audioPlayer.duration
            item.error = nil
            item.playbackOffset = nil
            item.playbackInitiator = initiator
            item.engagement = initiator == .direct ? .directInteraction : .unknown
            item.userActivity = TTSUserActivity(
                idleSecondsAtStart: idleSeconds(),
                idleSecondsAtEnd: nil,
                activityObserved: false,
                directInteraction: initiator == .direct,
                lastInteractionAt: initiator == .direct ? item.startedAt : nil,
                recordedAt: item.startedAt ?? Int64(Date().timeIntervalSince1970)
            )
            try store.save(item)

            player = audioPlayer
            isAudioPlaying = false
            currentItemID = item.id
            duration = audioPlayer.duration
            currentTime = audioPlayer.currentTime
            playbackRate = preferredRate
            replaceItem(item)
            if opensPaused {
                automaticallyPausedItemID = item.id
            } else {
                beginPlayback(audioPlayer, for: item)
            }
        } catch {
            fail(queuedItem, message: error.localizedDescription)
        }
    }

    func clearGlobalPauseForExplicitPlayback() -> Bool {
        guard isGloballyPaused else { return true }
        do {
            try store.setGlobalPlaybackPaused(false)
            isGloballyPaused = false
            return true
        } catch {
            NSLog("Unable to resume TTS for selected playback: %@", error.localizedDescription)
            return false
        }
    }

    func resumeCurrentItem(_ audioPlayer: AVAudioPlayer) {
        guard var item = currentItem else { return }
        guard item.status == .paused else { return }
        playbackStartTask?.cancel()
        playbackStartTask = nil
        automaticallyPausedItemID = nil
        item.status = .playing
        try? store.save(item)
        replaceItem(item)
        beginPlayback(audioPlayer, for: item)
    }

    func applyGlobalPlaybackPause(_ paused: Bool) {
        isGloballyPaused = paused
        updatePlaybackForBlockingState()
    }

    var isPlaybackBlocked: Bool {
        isGloballyPaused || isSystemOutputMuted
    }

    private func updatePlaybackForBlockingState() {
        playbackStartTask?.cancel()
        playbackStartTask = nil

        guard var item = currentItem, let player else { return }
        if isPlaybackBlocked {
            if item.status != .paused {
                automaticallyPausedItemID = item.id
            }
            player.pause()
            item.status = .paused
            isAudioPlaying = false
            try? store.save(item)
            replaceItem(item)
            mediaController.releaseForSpeechPause()
        } else if automaticallyPausedItemID == item.id {
            automaticallyPausedItemID = nil
            item.status = .playing
            try? store.save(item)
            replaceItem(item)
            beginPlayback(player, for: item)
        }
    }

    private func beginPlayback(_ audioPlayer: AVAudioPlayer, for item: TTSItem) {
        playbackStartTask?.cancel()
        playbackStartTask = Task { @MainActor [weak self, weak audioPlayer] in
            guard let self, let audioPlayer, self.player === audioPlayer else { return }
            let pausedMedia = await self.mediaController.prepareForSpeech(itemID: item.id)
            if pausedMedia {
                let delay = self.mediaController.mediaHandoffDelay
                try? await Task.sleep(for: .seconds(max(0, delay)))
            }
            guard !Task.isCancelled, self.player === audioPlayer else { return }
            self.playbackStartTask = nil
            guard !self.isPlaybackBlocked else { return }
            guard audioPlayer.play() else {
                self.finishCurrent(success: false, error: "The audio device refused playback.")
                return
            }
            self.isAudioPlaying = true
        }
    }
}
