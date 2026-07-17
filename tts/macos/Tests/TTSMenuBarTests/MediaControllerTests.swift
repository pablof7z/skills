import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct MediaControllerTests {
    @Test
    func pausesAndResumesOnlyTheOwnedSession() async throws {
        let backend = TestMediaControlBackend(session: session(playing: true))
        let controller = makeController(backend: backend)

        #expect(await controller.prepareForSpeech())
        #expect(backend.pauseCalls == 1)
        #expect(backend.session?.isPlaying == false)
        #expect(controller.hasActiveLease)

        controller.scheduleResume(after: 0, resumeAllowed: { true })
        try await waitUntil { !controller.hasActiveLease }

        #expect(backend.playCalls == 1)
        #expect(backend.session?.isPlaying == true)
    }

    @Test
    func pendingResumeCannotOverrideNewSpeech() async throws {
        let backend = TestMediaControlBackend(session: session(playing: true))
        let logger = TestMediaInterventionLogger()
        let controller = makeController(backend: backend, logger: logger)
        #expect(await controller.prepareForSpeech())

        controller.scheduleResume(after: 0.05, resumeAllowed: { true })
        try await Task.sleep(for: .milliseconds(5))
        #expect(!(await controller.prepareForSpeech()))
        try await Task.sleep(for: .milliseconds(70))

        #expect(backend.playCalls == 0)
        #expect(backend.session?.isPlaying == false)
        #expect(controller.hasActiveLease)
        #expect(logger.records.contains { $0.event == "resume_cancelled" && $0.reason == "new_speech" })
    }

    @Test
    func queuedSpeechAtResumeBoundaryKeepsTheLeasePaused() async throws {
        let backend = TestMediaControlBackend(session: session(playing: true))
        let logger = TestMediaInterventionLogger()
        let controller = makeController(backend: backend, logger: logger)
        #expect(await controller.prepareForSpeech())
        let queueState = TestQueueState(isIdle: false)

        controller.scheduleResume(after: 0, resumeAllowed: { queueState.isIdle })
        try await waitUntil {
            logger.records.contains { $0.event == "resume_deferred" && $0.reason == "queue_not_idle" }
        }

        #expect(backend.playCalls == 0)
        #expect(controller.hasActiveLease)
        queueState.isIdle = true
        controller.scheduleResume(after: 0, resumeAllowed: { queueState.isIdle })
        try await waitUntil { !controller.hasActiveLease }
        #expect(backend.playCalls == 1)
    }

    @Test
    func queueChangeDuringResumeRepausesMedia() async throws {
        let backend = TestMediaControlBackend(session: session(playing: true))
        let controller = makeController(backend: backend)
        #expect(await controller.prepareForSpeech())
        var queueIsIdle = true
        backend.onPlay = { queueIsIdle = false }

        controller.scheduleResume(after: 0, resumeAllowed: { queueIsIdle })
        try await waitUntil { backend.pauseCalls == 2 }

        #expect(backend.playCalls == 1)
        #expect(backend.session?.isPlaying == false)
        #expect(controller.hasActiveLease)
    }

    @Test
    func newSpeechRepausesAnInflightStaleResume() async throws {
        let backend = TestMediaControlBackend(session: session(playing: true))
        backend.playDelay = 0.03
        let controller = makeController(backend: backend)
        #expect(await controller.prepareForSpeech())

        controller.scheduleResume(after: 0, resumeAllowed: { true })
        try await waitUntil { backend.playStarted }
        #expect(!(await controller.prepareForSpeech()))
        try await waitUntil { backend.pauseCalls == 2 }

        #expect(backend.playCalls == 1)
        #expect(backend.session?.isPlaying == false)
        #expect(controller.hasActiveLease)
    }

    @Test
    func changedContentIsNeverResumed() async throws {
        let backend = TestMediaControlBackend(session: session(content: "track-a", playing: true))
        let controller = makeController(backend: backend)
        #expect(await controller.prepareForSpeech())
        backend.session = session(content: "track-b", playing: false)

        controller.scheduleResume(after: 0, resumeAllowed: { true })
        try await waitUntil { !controller.hasActiveLease }

        #expect(backend.playCalls == 0)
        #expect(backend.session?.isPlaying == false)
    }

    @Test
    func unverifiedPauseDoesNotDelaySpeechOrCreateOwnership() async {
        let backend = TestMediaControlBackend(session: session(playing: true))
        backend.pauseChangesState = false
        let logger = TestMediaInterventionLogger()
        let controller = makeController(backend: backend, logger: logger)

        #expect(!(await controller.prepareForSpeech()))
        #expect(!controller.hasActiveLease)
        #expect(backend.pauseCalls == 1)
        #expect(logger.records.contains {
            $0.event == "state_verification_timed_out" && $0.desiredPlaying == false
        })
    }

    @Test
    func shutdownRestoresTheOwnedSession() async {
        let backend = TestMediaControlBackend(session: session(playing: true))
        let controller = makeController(backend: backend)
        #expect(await controller.prepareForSpeech())

        controller.shutdown()

        #expect(backend.shutdownRestoreCalls == 1)
        #expect(backend.session?.isPlaying == true)
        #expect(!controller.hasActiveLease)
    }

    @Test
    func recordsCorrelatedPauseAndResumeLifecycle() async throws {
        let backend = TestMediaControlBackend(session: session(playing: true))
        let logger = TestMediaInterventionLogger()
        let controller = makeController(backend: backend, logger: logger)

        #expect(await controller.prepareForSpeech(itemID: "speech-123"))
        controller.scheduleResume(after: 0, resumeAllowed: { true })
        try await waitUntil { !controller.hasActiveLease }

        let correlated = logger.records.filter { $0.itemID == "speech-123" }
        let events = correlated.map(\.event)
        #expect(events.contains("lease_acquired"))
        #expect(events.contains("resume_scheduled"))
        #expect(events.contains("resume_requested"))
        #expect(correlated.contains { $0.event == "state_verified" && $0.desiredPlaying == true })
        #expect(correlated.contains { $0.event == "lease_released" && $0.reason == "resume_verified" })
        #expect(Set(correlated.compactMap(\.leaseID)).count == 1)
    }

    private func makeController(
        backend: TestMediaControlBackend,
        logger: (any MediaInterventionLogging)? = nil
    ) -> MediaController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-controller-tests-\(UUID().uuidString)")
        let preferences = PlayerPreferencesStore(stateDirectory: directory)
        preferences.setPausesMedia(true)
        return MediaController(
            preferencesStore: preferences,
            backends: [backend],
            logger: logger,
            verificationAttempts: 3,
            verificationDelay: 0.001
        )
    }

    private func session(
        content: String = "track-a",
        playing: Bool
    ) -> MediaSessionSnapshot {
        MediaSessionSnapshot(
            bundleIdentifier: "com.example.player",
            processIdentifier: 42,
            contentIdentifier: content,
            title: "Silent track",
            artist: "Tests",
            album: nil,
            isPlaying: playing
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition did not become true before timeout.")
    }
}

@MainActor
private final class TestMediaInterventionLogger: MediaInterventionLogging {
    var records: [MediaInterventionRecord] = []

    func record(_ record: MediaInterventionRecord) {
        records.append(record)
    }
}

@MainActor
private final class TestMediaControlBackend: MediaControlBackend {
    let name = "test"
    var session: MediaSessionSnapshot?
    var pauseCalls = 0
    var playCalls = 0
    var pauseChangesState = true
    var onPlay: (() -> Void)?
    var playDelay: TimeInterval = 0
    var playStarted = false
    var shutdownRestoreCalls = 0

    init(session: MediaSessionSnapshot?) {
        self.session = session
    }

    func sessions() async throws -> [MediaSessionSnapshot] {
        session.map { [$0] } ?? []
    }

    func pause(_: MediaSessionSnapshot) async throws -> Bool {
        pauseCalls += 1
        if pauseChangesState, let session {
            self.session = replacingPlaybackState(of: session, with: false)
        }
        return true
    }

    func play(_: MediaSessionSnapshot) async throws -> Bool {
        playCalls += 1
        playStarted = true
        if playDelay > 0 {
            try await Task.sleep(for: .seconds(playDelay))
        }
        onPlay?()
        if let session {
            self.session = replacingPlaybackState(of: session, with: true)
        }
        return true
    }

    func restoreOnShutdown(_: MediaSessionSnapshot) -> Bool {
        shutdownRestoreCalls += 1
        guard let session, !session.isPlaying else { return false }
        self.session = replacingPlaybackState(of: session, with: true)
        return true
    }

    private func replacingPlaybackState(
        of session: MediaSessionSnapshot,
        with isPlaying: Bool
    ) -> MediaSessionSnapshot {
        MediaSessionSnapshot(
            bundleIdentifier: session.bundleIdentifier,
            processIdentifier: session.processIdentifier,
            contentIdentifier: session.contentIdentifier,
            title: session.title,
            artist: session.artist,
            album: session.album,
            isPlaying: isPlaying
        )
    }
}

@MainActor
private final class TestQueueState {
    var isIdle: Bool

    init(isIdle: Bool) {
        self.isIdle = isIdle
    }
}
