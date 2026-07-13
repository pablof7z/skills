import AVFAudio
import AppKit
import Foundation

@MainActor
final class PlaybackController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var items: [TTSItem] = []
    @Published private(set) var currentItemID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let store: QueueStore
    private let mediaController: MediaController
    private var player: AVAudioPlayer?
    private var refreshTimer: Timer?
    private var playbackStartTask: Task<Void, Never>?
    private var started = false

    init(store: QueueStore = QueueStore(), mediaController: MediaController = MediaController()) {
        self.store = store
        self.mediaController = mediaController
        super.init()
    }

    var currentItem: TTSItem? {
        guard let currentItemID else { return nil }
        return items.first { $0.id == currentItemID }
    }

    var queuedItems: [TTSItem] {
        items.filter { $0.status.isPending }
    }

    var recentItems: [TTSItem] {
        items.filter { $0.status.isRecent }
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
        mediaController.resumePausedAppsImmediately()
    }

    func togglePause() {
        guard var item = currentItem, let player else { return }
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

    func rewind(seconds: TimeInterval = 15) {
        skip(by: -seconds)
    }

    func forward(seconds: TimeInterval = 15) {
        skip(by: seconds)
    }

    func stop() {
        guard player != nil else { return }
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

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishCurrent(success: flag, error: flag ? nil : "Playback stopped before completion.")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishCurrent(success: false, error: error?.localizedDescription ?? "Unable to decode audio.")
    }

    private func refresh() {
        do {
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
            } else if let next = loaded.first(where: { $0.status == .queued }) {
                play(next)
            }
        } catch {
            NSLog("Unable to refresh TTS queue: %@", error.localizedDescription)
        }
    }

    private func play(_ queuedItem: TTSItem) {
        guard FileManager.default.fileExists(atPath: queuedItem.outputFile) else {
            fail(queuedItem, message: "Audio file is no longer available.")
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: queuedItem.outputFile))
            audioPlayer.delegate = self
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

            let pausedMedia = mediaController.pausePlayingApps()
            player = audioPlayer
            currentItemID = item.id
            duration = audioPlayer.duration
            currentTime = audioPlayer.currentTime
            replaceItem(item)

            if pausedMedia {
                let delay = queuedItem.mediaHandoffDelay
                    ?? TimeInterval(ProcessInfo.processInfo.environment["TTS_MEDIA_HANDOFF_DELAY_SECONDS"] ?? "2")
                    ?? 2
                playbackStartTask?.cancel()
                playbackStartTask = Task { @MainActor [weak self, weak audioPlayer] in
                    try? await Task.sleep(for: .seconds(max(0, delay)))
                    guard !Task.isCancelled, let self, let audioPlayer, self.player === audioPlayer else { return }
                    self.playbackStartTask = nil
                    guard audioPlayer.play() else {
                        self.finishCurrent(success: false, error: "The audio device refused playback.")
                        return
                    }
                }
            } else if !audioPlayer.play() {
                finishCurrent(success: false, error: "The audio device refused playback.")
            }
        } catch {
            fail(queuedItem, message: error.localizedDescription)
        }
    }

    private func finishCurrent(success: Bool, error: String?) {
        guard var item = currentItem else { return }
        playbackStartTask?.cancel()
        playbackStartTask = nil
        item.status = success ? .played : .failed
        item.completedAt = Int64(Date().timeIntervalSince1970)
        item.duration = player?.duration ?? item.duration
        item.error = error
        try? store.save(item)

        player = nil
        currentItemID = nil
        currentTime = 0
        duration = 0
        replaceItem(item)

        let hasQueuedItem = (try? store.loadItems().contains { $0.status == .queued }) ?? false
        if hasQueuedItem {
            refresh()
        } else {
            let delay = TimeInterval(ProcessInfo.processInfo.environment["TTS_RESUME_DELAY_SECONDS"] ?? "3") ?? 3
            mediaController.resumePausedApps(after: delay)
        }
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
