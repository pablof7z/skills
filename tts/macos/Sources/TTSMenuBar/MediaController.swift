import Foundation

@MainActor
final class MediaController {
    struct InterruptionLease {
        let id: UUID
        var generation: UInt64
        var itemID: String?
        let backend: any MediaControlBackend
        var session: MediaSessionSnapshot
    }

    var generation: UInt64 = 0
    var activeLease: InterruptionLease?
    var resumeTask: Task<Void, Never>?
    let logger: any MediaInterventionLogging
    private let preferencesStore: PlayerPreferencesStore
    private let backends: [any MediaControlBackend]
    private let verificationAttempts: Int
    private let verificationDelay: TimeInterval

    init(
        preferencesStore: PlayerPreferencesStore,
        backends: [any MediaControlBackend]? = nil,
        logger: (any MediaInterventionLogging)? = nil,
        verificationAttempts: Int = 10,
        verificationDelay: TimeInterval = 0.05
    ) {
        self.preferencesStore = preferencesStore
        self.logger = logger ?? MediaInterventionLogger(
            stateDirectory: preferencesStore.fileURL.deletingLastPathComponent()
        )
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationDelay = max(0, verificationDelay)
        if let backends {
            self.backends = backends
        } else {
            self.backends = [AppleScriptMediaControlBackend()]
        }
    }

    func prepareForSpeech(itemID: String? = nil) async -> Bool {
        guard mediaControlEnabled else {
            trace("prepare_skipped", itemID: itemID, reason: "media_control_disabled")
            shutdown(reason: "media_control_disabled")
            return false
        }
        if resumeTask != nil {
            trace("resume_cancelled", itemID: itemID, lease: activeLease, reason: "new_speech")
        }
        resumeTask?.cancel()
        resumeTask = nil
        generation &+= 1
        trace("prepare_started", itemID: itemID)

        if var lease = activeLease {
            lease.generation = generation
            lease.itemID = itemID
            activeLease = lease
            trace("lease_reused", lease: lease)
            if let current = await matchingSession(for: lease) {
                if !current.isPlaying {
                    activeLease?.session = current
                    trace("pause_skipped", lease: lease, session: current, reason: "already_paused")
                    return false
                }
                if let paused = await pauseAndVerify(current, with: lease.backend, lease: lease) {
                    activeLease?.session = paused
                    trace("lease_retained", lease: lease, session: paused, reason: "new_speech")
                    return true
                }
            }
            trace("lease_released", lease: lease, reason: "session_missing_or_pause_failed")
            activeLease = nil
        }

        for backend in backends {
            do {
                guard let playing = try await backend.sessions().first(where: \.isPlaying) else {
                    trace("pause_skipped", itemID: itemID, backend: backend, reason: "no_playing_session")
                    continue
                }
                let leaseID = UUID()
                guard let paused = await pauseAndVerify(
                    playing,
                    with: backend,
                    itemID: itemID,
                    leaseID: leaseID
                ) else {
                    continue
                }
                activeLease = InterruptionLease(
                    id: leaseID,
                    generation: generation,
                    itemID: itemID,
                    backend: backend,
                    session: paused
                )
                trace("lease_acquired", lease: activeLease, session: paused)
                return true
            } catch {
                trace("backend_failed", itemID: itemID, backend: backend, error: error)
                NSLog("%@ media backend unavailable: %@", backend.name, error.localizedDescription)
            }
        }
        trace("prepare_finished", itemID: itemID, reason: "no_session_paused")
        return false
    }

    var mediaHandoffDelay: TimeInterval {
        preferencesStore.preferences.mediaHandoffDelay
    }

    var mediaResumeDelay: TimeInterval {
        preferencesStore.preferences.mediaResumeDelay
    }

    var hasActiveLease: Bool { activeLease != nil }

    private var mediaControlEnabled: Bool {
        preferencesStore.preferences.pausesMedia
    }

    func pauseAndVerify(
        _ session: MediaSessionSnapshot,
        with backend: any MediaControlBackend,
        itemID: String? = nil,
        leaseID: UUID? = nil,
        lease: InterruptionLease? = nil
    ) async -> MediaSessionSnapshot? {
        trace(
            "pause_requested",
            itemID: itemID,
            lease: lease,
            leaseID: leaseID,
            backend: backend,
            session: session
        )
        do {
            guard try await backend.pause(session) else {
                trace("pause_rejected", itemID: itemID, lease: lease, leaseID: leaseID, backend: backend)
                return nil
            }
            return await waitForState(
                false,
                session: session,
                backend: backend,
                itemID: itemID,
                leaseID: leaseID,
                lease: lease
            )
        } catch {
            trace("pause_failed", itemID: itemID, lease: lease, leaseID: leaseID, backend: backend, error: error)
            NSLog("%@ failed to pause media: %@", backend.name, error.localizedDescription)
            return nil
        }
    }

    func matchingSession(for lease: InterruptionLease) async -> MediaSessionSnapshot? {
        do {
            let session = try await lease.backend.sessions().first {
                $0.belongsToSameSession(as: lease.session)
            }
            trace(
                session == nil ? "session_missing" : "session_observed",
                lease: lease,
                session: session,
                reason: session == nil ? "owned_session_not_found" : nil
            )
            return session
        } catch {
            trace("session_lookup_failed", lease: lease, error: error)
            NSLog("%@ failed to read media state: %@", lease.backend.name, error.localizedDescription)
            return nil
        }
    }

    func waitForState(
        _ isPlaying: Bool,
        session: MediaSessionSnapshot,
        backend: any MediaControlBackend,
        itemID: String? = nil,
        leaseID: UUID? = nil,
        lease: InterruptionLease? = nil
    ) async -> MediaSessionSnapshot? {
        var lastObserved: MediaSessionSnapshot?
        for attempt in 0..<verificationAttempts {
            do {
                lastObserved = try await backend.sessions().first(where: {
                    $0.belongsToSameSession(as: session)
                })
                if let current = lastObserved, current.isPlaying == isPlaying {
                    trace(
                        "state_verified",
                        itemID: itemID,
                        lease: lease,
                        leaseID: leaseID,
                        backend: backend,
                        session: current,
                        desiredPlaying: isPlaying,
                        attempt: attempt + 1
                    )
                    return current
                }
            } catch {
                trace(
                    "state_verification_failed",
                    itemID: itemID,
                    lease: lease,
                    leaseID: leaseID,
                    backend: backend,
                    desiredPlaying: isPlaying,
                    attempt: attempt + 1,
                    error: error
                )
                NSLog("%@ failed to verify media state: %@", backend.name, error.localizedDescription)
                return nil
            }
            if attempt < verificationAttempts - 1 {
                try? await Task.sleep(for: .seconds(verificationDelay))
            }
        }
        trace(
            "state_verification_timed_out",
            itemID: itemID,
            lease: lease,
            leaseID: leaseID,
            backend: backend,
            session: lastObserved,
            desiredPlaying: isPlaying,
            attempt: verificationAttempts
        )
        return nil
    }
}
