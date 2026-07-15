import AVFAudio
import AppKit
import Foundation

@MainActor
final class PlaybackController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var items: [TTSItem] = []
    @Published private(set) var currentItemID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1.0
    @Published private(set) var isGloballyPaused = false
    @Published private(set) var isSystemOutputMuted = false
    @Published private(set) var isAudioPlaying = false
    @Published private(set) var generationProgressNow = Date()
    @Published private(set) var historyTimestampNow = Date()

    private let store: QueueStore
    private let mediaController: MediaController
    private let playbackRateStore: VoicePlaybackRateStore
    private let outputIsMuted: () -> Bool
    private let idleSeconds: () -> TimeInterval
    private var player: AVAudioPlayer?
    private var refreshTimer: Timer?
    private var playbackStartTask: Task<Void, Never>?
    private var automaticallyPausedItemID: String?
    private var retryingItemIDs = Set<String>()
    private var isAutomaticQueueAdvanceDeferred = false
    private var started = false
    private var lastHistoryTimestampRefresh = Date.distantPast

    init(
        store: QueueStore = QueueStore(),
        mediaController: MediaController? = nil,
        playbackRateStore: VoicePlaybackRateStore? = nil,
        outputIsMuted: @escaping () -> Bool = { SystemOutputMuteReader().isMuted() },
        idleSeconds: @escaping () -> TimeInterval = {
            [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel]
                .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
                .min() ?? .infinity
        }
    ) {
        self.store = store
        self.mediaController = mediaController ?? MediaController(
            preferencesStore: PlayerPreferencesStore(stateDirectory: store.stateDirectory)
        )
        self.playbackRateStore = playbackRateStore
            ?? VoicePlaybackRateStore(stateDirectory: store.stateDirectory)
        self.outputIsMuted = outputIsMuted
        self.idleSeconds = idleSeconds
        super.init()
    }

    var currentItem: TTSItem? {
        guard let currentItemID else { return nil }
        return items.first { $0.id == currentItemID }
    }

    var queuedItems: [TTSItem] {
        items.filter { $0.status.isPending && !$0.isAttachmentPlayback }
    }

    var nextQueuedItem: TTSItem? {
        Self.nextQueuedItem(in: items)
    }

    var recentItems: [TTSItem] {
        items.filter { $0.status.isRecent && !$0.isAttachmentPlayback && !$0.archived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var playerListItems: [TTSItem] {
        items.filter {
            ($0.status == .generating || $0.status.isRecent)
                && !$0.isAttachmentPlayback
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    var activeHistoryItems: [TTSItem] {
        playerListItems.filter { !$0.archived }
    }

    var archivedHistoryItems: [TTSItem] {
        playerListItems.filter(\.archived)
    }

    var isGenerating: Bool {
        items.contains { $0.status == .generating && !$0.isAttachmentPlayback }
    }

    var isPaused: Bool {
        currentItem?.status == .paused
    }

    func generationProgress(for item: TTSItem) -> Double {
        GenerationProgress.value(for: item, samples: items, now: generationProgressNow)
    }

    func setAutomaticQueueAdvanceDeferred(_ deferred: Bool) {
        guard deferred != isAutomaticQueueAdvanceDeferred else { return }
        isAutomaticQueueAdvanceDeferred = deferred
        if !deferred {
            refresh()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try store.prepare()
            try store.recoverInterruptedItems()
            isGloballyPaused = store.isGlobalPlaybackPaused()
            isSystemOutputMuted = outputIsMuted()
        } catch {
            NSLog("TTS queue initialization failed: %@", error.localizedDescription)
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func shutdown() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if var item = currentItem {
            player?.stop()
            item.status = .queued
            item.startedAt = nil
            item.completedAt = nil
            try? store.save(item)
        }
        player = nil
        isAudioPlaying = false
        currentItemID = nil
        automaticallyPausedItemID = nil
        mediaController.resumePausedAppsImmediately()
    }

    func togglePause() {
        if isGloballyPaused {
            setGlobalPlaybackPaused(false)
            return
        }
        guard !isSystemOutputMuted else { return }
        guard var item = currentItem, let player else { return }
        automaticallyPausedItemID = nil
        markDirectInteraction(on: &item)
        if player.isPlaying {
            player.pause()
            item.status = .paused
            isAudioPlaying = false
        } else {
            player.play()
            item.status = .playing
            isAudioPlaying = true
        }
        try? store.save(item)
        replaceItem(item)
    }

    func toggleGlobalPlaybackPause() {
        setGlobalPlaybackPaused(!isGloballyPaused)
    }

    func setGlobalPlaybackPaused(_ paused: Bool) {
        guard paused != isGloballyPaused else { return }
        do {
            try store.setGlobalPlaybackPaused(paused)
        } catch {
            NSLog("Unable to update global TTS pause: %@", error.localizedDescription)
            return
        }
        applyGlobalPlaybackPause(paused)
    }

    func rewind(seconds: TimeInterval = 15) {
        skip(by: -seconds)
    }

    func forward(seconds: TimeInterval = 15) {
        skip(by: seconds)
    }

    func stop() {
        guard player != nil else { return }
        if var item = currentItem, item.isAttachmentPlayback {
            item.returnToPlaybackOffset = nil
            try? store.save(item)
            replaceItem(item)
        }
        playbackStartTask?.cancel()
        playbackStartTask = nil
        recordDirectInteraction()
        player?.stop()
        finishCurrent(success: true, error: nil, terminalStatus: .interrupted)
    }

    private func skip(by seconds: TimeInterval) {
        guard let player else { return }
        recordDirectInteraction()
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
        currentTime = player.currentTime
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        recordDirectInteraction()
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func cyclePlaybackRate(for item: TTSItem) {
        if currentItem?.id == item.id { recordDirectInteraction() }
        let current = currentItem?.id == item.id
            ? playbackRate
            : playbackRateStore.rate(for: item.voice)
        setPlaybackRate(VoicePlaybackRateStore.nextRate(after: current), for: item)
    }

    func setPlaybackRate(_ rate: Float, for item: TTSItem) {
        guard VoicePlaybackRateStore.availableRates.contains(where: { abs($0 - rate) < 0.001 }) else {
            return
        }
        try? playbackRateStore.save(rate, for: item.voice)
        playbackRate = rate
        if currentItem?.id == item.id, let player {
            player.enableRate = true
            player.rate = rate
        }
    }

    var playbackRateLabel: String {
        VoicePlaybackRateStore.label(for: playbackRate)
    }

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
            resumeCurrentItem(player)
            return
        }

        if currentItem != nil {
            finishCurrentForReplacement()
        }

        let requested = item.status == .queued ? item : item.requeuedForReplay()
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
        } catch {
            NSLog("Unable to answer TTS question: %@", error.localizedDescription)
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
        } catch {
            NSLog("Unable to submit TTS question bundle: %@", error.localizedDescription)
            refresh()
        }
    }

    func playAttachment(_ attachment: TTSAttachment, from displayedItem: TTSItem) {
        let brief = displayedItem.parentItemID
            .flatMap { parentID in items.first(where: { $0.id == parentID }) }
            ?? displayedItem
        guard let audioFile = attachment.audioFile,
              FileManager.default.fileExists(atPath: audioFile) else { return }

        let pendingChild = items.first {
            $0.parentItemID == brief.id
                && $0.attachmentID == attachment.id
                && ($0.status == .queued || $0.status == .playing || $0.status == .paused)
        }
        if let pendingChild, currentItem?.id == pendingChild.id {
            return
        }

        var returnOffset: TimeInterval?
        if let current = currentItem, let player {
            if current.isAttachmentPlayback {
                returnOffset = current.returnToPlaybackOffset
            } else if current.id == brief.id {
                returnOffset = player.currentTime
            }
            finishCurrentForReplacement()
        }

        if var pendingChild {
            if let returnOffset {
                pendingChild.returnToPlaybackOffset = returnOffset
                try? store.save(pendingChild)
                replaceItem(pendingChild)
            }
            play(pendingChild)
            return
        }

        guard let child = brief.attachmentPlaybackItem(
            attachment,
            returnTo: returnOffset
        ) else { return }
        do {
            try store.save(child)
            replaceItem(child)
            play(child)
        } catch {
            NSLog("Unable to play TTS attachment: %@", error.localizedDescription)
        }
    }

    func openAttachment(_ attachment: TTSAttachment) {
        let url = URL(fileURLWithPath: attachment.sourceFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func returnToParent(from displayedItem: TTSItem) {
        guard let parentID = displayedItem.parentItemID,
              let parent = items.first(where: { $0.id == parentID }) else { return }
        let offset = displayedItem.returnToPlaybackOffset ?? 0
        if currentItem?.id == displayedItem.id {
            finishCurrentForReplacement()
        }
        let resumed = parent.requeuedForReplay(startingAt: offset)
        do {
            try store.save(resumed)
            replaceItem(resumed)
            if isPlaybackBlocked {
                refresh()
            } else {
                play(resumed)
            }
        } catch {
            NSLog("Unable to return to parent TTS item: %@", error.localizedDescription)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishCurrent(success: flag, error: flag ? nil : "Playback stopped before completion.")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishCurrent(success: false, error: error?.localizedDescription ?? "Unable to decode audio.")
    }

    private func refresh() {
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
            let loaded = try store.loadItems()
            if loaded != items {
                items = loaded
            }
            if loaded.contains(where: { $0.status == .generating && !$0.isAttachmentPlayback }) {
                generationProgressNow = now
            }
            if now.timeIntervalSince(lastHistoryTimestampRefresh) >= 1 {
                historyTimestampNow = now
                lastHistoryTimestampRefresh = now
            }
            if let player {
                let nextTime = player.currentTime
                let nextDuration = player.duration
                if abs(currentTime - nextTime) > 0.001 {
                    currentTime = nextTime
                }
                if abs(duration - nextDuration) > 0.001 {
                    duration = nextDuration
                }
            } else if !isPlaybackBlocked,
                      !isAutomaticQueueAdvanceDeferred,
                      let next = Self.nextQueuedItem(in: loaded) {
                play(next)
            }
        } catch {
            NSLog("Unable to refresh TTS queue: %@", error.localizedDescription)
        }
    }

    static func nextQueuedItem(in items: [TTSItem]) -> TTSItem? {
        items.first { $0.status == .queued && $0.isAttachmentPlayback }
            ?? items.first { $0.status == .queued }
    }

    private func play(
        _ queuedItem: TTSItem,
        initiator: TTSPlaybackInitiator = .automatic
    ) {
        guard !isPlaybackBlocked else { return }
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
            item.status = .playing
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
            beginPlayback(audioPlayer, for: item)
        } catch {
            fail(queuedItem, message: error.localizedDescription)
        }
    }

    private func clearGlobalPauseForExplicitPlayback() -> Bool {
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

    private func resumeCurrentItem(_ audioPlayer: AVAudioPlayer) {
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

    private func applyGlobalPlaybackPause(_ paused: Bool) {
        isGloballyPaused = paused
        updatePlaybackForBlockingState()
    }

    private var isPlaybackBlocked: Bool {
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
            mediaController.resumePausedAppsImmediately()
        } else if automaticallyPausedItemID == item.id {
            automaticallyPausedItemID = nil
            item.status = .playing
            try? store.save(item)
            replaceItem(item)
            beginPlayback(player, for: item)
        }
    }

    private func beginPlayback(_ audioPlayer: AVAudioPlayer, for item: TTSItem) {
        let pausedMedia = mediaController.pausePlayingApps()
        if pausedMedia {
            let delay = mediaController.mediaHandoffDelay
            playbackStartTask?.cancel()
            playbackStartTask = Task { @MainActor [weak self, weak audioPlayer] in
                try? await Task.sleep(for: .seconds(max(0, delay)))
                guard !Task.isCancelled, let self, let audioPlayer, self.player === audioPlayer else { return }
                self.playbackStartTask = nil
                guard !self.isPlaybackBlocked else { return }
                guard audioPlayer.play() else {
                    self.finishCurrent(success: false, error: "The audio device refused playback.")
                    return
                }
                self.isAudioPlaying = true
            }
        } else {
            guard audioPlayer.play() else {
                finishCurrent(success: false, error: "The audio device refused playback.")
                return
            }
            isAudioPlaying = true
        }
    }

    private func finishCurrent(
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

    private func finishCurrentForReplacement() {
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

    private func fail(_ item: TTSItem, message: String) {
        var failed = item
        failed.status = .failed
        failed.completedAt = Int64(Date().timeIntervalSince1970)
        failed.error = message
        try? store.save(failed)
        replaceItem(failed)
    }

    private func retryCommand(for item: TTSItem) -> String? {
        let candidates = [
            item.retryCommand,
            NSString(string: "~/.agents/skills/tts/scripts/tts").expandingTildeInPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func recordRetryFailure(for item: TTSItem, message: String) {
        var failed = item
        failed.error = message
        failed.completedAt = Int64(Date().timeIntervalSince1970)
        try? store.save(failed)
        replaceItem(failed)
    }

    private func replaceItem(_ item: TTSItem) {
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
    }

    private func recordDirectInteraction() {
        guard var item = currentItem else { return }
        markDirectInteraction(on: &item)
        try? store.save(item)
        replaceItem(item)
    }

    private func markDirectInteraction(on item: inout TTSItem) {
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
