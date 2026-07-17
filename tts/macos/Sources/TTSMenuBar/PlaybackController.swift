import AVFAudio
import AppKit
import Foundation

@MainActor
final class PlaybackController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published internal(set) var items: [TTSItem] = []
    @Published internal(set) var currentItemID: String?
    @Published internal(set) var currentTime: TimeInterval = 0
    @Published internal(set) var duration: TimeInterval = 0
    @Published internal(set) var playbackRate: Float = 1.0
    @Published internal(set) var isGloballyPaused = false
    @Published internal(set) var isSystemOutputMuted = false
    @Published internal(set) var isAudioPlaying = false
    @Published internal(set) var generationProgressNow = Date()
    let historyTimestampClock = HistoryTimestampClock()
    internal(set) var historyRevision = 0

    let store: QueueStore
    let mediaController: MediaController
    let playbackRateStore: VoicePlaybackRateStore
    let outputIsMuted: () -> Bool
    let idleSeconds: () -> TimeInterval
    var player: AVAudioPlayer?
    var refreshTimer: Timer?
    var playbackStartTask: Task<Void, Never>?
    var automaticallyPausedItemID: String?
    var explicitlyOpenedInactiveItemID: String?
    var retryingItemIDs = Set<String>()
    @Published var visibleAskQueueHoldID: String?
    var started = false
    var lastItemsChangeToken: Date?

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
        items.filter {
            $0.status.isPending
                && !$0.isAttachmentPlayback
                && QueuePlaybackPolicy.isActive($0, in: items)
        }
    }

    var nextPlaybackRequestItem: TTSItem? {
        try? store.pendingPlaybackItem(heldItemID: nil)
    }

    var recentItems: [TTSItem] {
        items.filter { $0.status.isRecent && !$0.isAttachmentPlayback && !$0.archived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var playerListItems: [TTSItem] {
        items.filter {
            PlayerListPolicy.includes(
                $0.status,
                playbackRequested: $0.playbackRequested
            ) && !$0.isAttachmentPlayback
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

    var queueAutoplayBlockers: [QueueAutoplayBlocker] {
        QueueAutoplayBlockerPolicy.blockers(
            isGloballyPaused: isGloballyPaused,
            isSystemOutputMuted: isSystemOutputMuted,
            visibleAskQueueHoldID: visibleAskQueueHoldID
        )
    }

    func generationProgress(for item: TTSItem) -> Double {
        GenerationProgress.value(for: item, samples: items, now: generationProgressNow)
    }

    func setVisibleAskQueueHold(_ itemID: String?) {
        guard visibleAskQueueHoldID != itemID else { return }
        visibleAskQueueHoldID = itemID
        refresh()
    }

    func clearVisibleAskQueueHold(for itemID: String? = nil) {
        guard let heldID = visibleAskQueueHoldID,
              itemID == nil || itemID == heldID else { return }
        setVisibleAskQueueHold(nil)
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
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func shutdown() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        parkCurrentForShutdown()
        player = nil
        isAudioPlaying = false
        currentItemID = nil
        automaticallyPausedItemID = nil
        explicitlyOpenedInactiveItemID = nil
        mediaController.shutdown()
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
            discardWaitingPlaybackAdmissions()
            player.pause()
            item.status = .paused
            isAudioPlaying = false
            try? store.save(item)
            replaceItem(item)
            mediaController.releaseForSpeechPause()
            return
        }
        try? store.save(item)
        replaceItem(item)
        resumeCurrentItem(player)
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
        discardWaitingPlaybackAdmissions()
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

    private func discardWaitingPlaybackAdmissions() {
        do {
            try store.discardAllPlaybackAdmissions()
        } catch {
            NSLog("Unable to stop waiting TTS playback requests: %@", error.localizedDescription)
        }
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
}
