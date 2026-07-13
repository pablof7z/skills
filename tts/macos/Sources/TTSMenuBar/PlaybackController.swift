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

    private let store: QueueStore
    private let mediaController: MediaController
    private let playbackRateStore: VoicePlaybackRateStore
    private let outputIsMuted: () -> Bool
    private var player: AVAudioPlayer?
    private var refreshTimer: Timer?
    private var playbackStartTask: Task<Void, Never>?
    private var automaticallyPausedItemID: String?
    private var started = false

    init(
        store: QueueStore = QueueStore(),
        mediaController: MediaController = MediaController(),
        playbackRateStore: VoicePlaybackRateStore? = nil,
        outputIsMuted: @escaping () -> Bool = { SystemOutputMuteReader().isMuted() }
    ) {
        self.store = store
        self.mediaController = mediaController
        self.playbackRateStore = playbackRateStore
            ?? VoicePlaybackRateStore(stateDirectory: store.stateDirectory)
        self.outputIsMuted = outputIsMuted
        super.init()
    }

    var currentItem: TTSItem? {
        guard let currentItemID else { return nil }
        return items.first { $0.id == currentItemID }
    }

    var queuedItems: [TTSItem] {
        items.filter { $0.status.isPending && !$0.isAttachmentPlayback }
    }

    var recentItems: [TTSItem] {
        items.filter { $0.status.isRecent && !$0.isAttachmentPlayback }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var isPaused: Bool {
        currentItem?.status == .paused
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
        if player.isPlaying {
            player.pause()
            item.status = .paused
        } else {
            player.play()
            item.status = .playing
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
        player?.stop()
        finishCurrent(success: true, error: nil)
    }

    private func skip(by seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
        currentTime = player.currentTime
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func cyclePlaybackRate(for item: TTSItem) {
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
            try store.save(item.replayCopy(startingAt: offset))
            refresh()
        } catch {
            NSLog("Unable to queue replay: %@", error.localizedDescription)
        }
    }

    func reveal(_ item: TTSItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.outputFile)])
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
        let resumed = parent.replayCopy(startingAt: offset)
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

    private func play(_ queuedItem: TTSItem) {
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
            try store.save(item)

            player = audioPlayer
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
            let delay = item.mediaHandoffDelay
                ?? TimeInterval(ProcessInfo.processInfo.environment["TTS_MEDIA_HANDOFF_DELAY_SECONDS"] ?? "2")
                ?? 2
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
            }
        } else if !audioPlayer.play() {
            finishCurrent(success: false, error: "The audio device refused playback.")
        }
    }

    private func finishCurrent(success: Bool, error: String?) {
        guard var item = currentItem else { return }
        let parentReturn = success
            ? item.parentItemID.flatMap { parentID in
                item.returnToPlaybackOffset.map { (parentID, $0) }
            }
            : nil
        playbackStartTask?.cancel()
        playbackStartTask = nil
        item.status = success ? .played : .failed
        item.completedAt = Int64(Date().timeIntervalSince1970)
        item.duration = player?.duration ?? item.duration
        item.error = error
        try? store.save(item)

        player = nil
        currentItemID = nil
        automaticallyPausedItemID = nil
        currentTime = 0
        duration = 0
        replaceItem(item)

        if let (parentID, offset) = parentReturn,
           let parent = (try? store.loadItems())?.first(where: { $0.id == parentID }) {
            let resumed = parent.replayCopy(startingAt: offset)
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
            let delay = TimeInterval(ProcessInfo.processInfo.environment["TTS_RESUME_DELAY_SECONDS"] ?? "3") ?? 3
            mediaController.resumePausedApps(after: delay)
        }
    }

    private func finishCurrentForReplacement() {
        guard var item = currentItem else { return }
        playbackStartTask?.cancel()
        playbackStartTask = nil
        player?.stop()
        item.status = .played
        item.completedAt = Int64(Date().timeIntervalSince1970)
        item.duration = player?.duration ?? item.duration
        item.error = nil
        try? store.save(item)

        player = nil
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
}
