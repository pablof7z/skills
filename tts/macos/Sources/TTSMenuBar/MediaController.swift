import Foundation

@MainActor
final class MediaController {
    private struct InterruptionLease {
        var generation: UInt64
        let backend: any MediaControlBackend
        var session: MediaSessionSnapshot
    }

    private var generation: UInt64 = 0
    private var activeLease: InterruptionLease?
    private var resumeTask: Task<Void, Never>?
    private let preferencesStore: PlayerPreferencesStore
    private let backends: [any MediaControlBackend]
    private let verificationAttempts: Int
    private let verificationDelay: TimeInterval

    init(
        preferencesStore: PlayerPreferencesStore,
        backends: [any MediaControlBackend]? = nil,
        verificationAttempts: Int = 10,
        verificationDelay: TimeInterval = 0.05
    ) {
        self.preferencesStore = preferencesStore
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationDelay = max(0, verificationDelay)
        if let backends {
            self.backends = backends
        } else {
            self.backends = [AppleScriptMediaControlBackend()]
        }
    }

    func prepareForSpeech() async -> Bool {
        guard mediaControlEnabled else {
            shutdown()
            return false
        }
        resumeTask?.cancel()
        resumeTask = nil
        generation &+= 1

        if var lease = activeLease {
            lease.generation = generation
            activeLease = lease
            if let current = await matchingSession(for: lease) {
                if !current.isPlaying {
                    activeLease?.session = current
                    return false
                }
                if let paused = await pauseAndVerify(current, with: lease.backend) {
                    activeLease?.session = paused
                    return true
                }
            }
            activeLease = nil
        }

        for backend in backends {
            do {
                guard let playing = try await backend.sessions().first(where: \.isPlaying) else {
                    continue
                }
                guard let paused = await pauseAndVerify(playing, with: backend) else {
                    continue
                }
                activeLease = InterruptionLease(
                    generation: generation,
                    backend: backend,
                    session: paused
                )
                return true
            } catch {
                NSLog("%@ media backend unavailable: %@", backend.name, error.localizedDescription)
            }
        }
        return false
    }

    func scheduleResume(
        after delay: TimeInterval,
        resumeAllowed: @escaping @MainActor () -> Bool
    ) {
        resumeTask?.cancel()
        guard var lease = activeLease else { return }
        generation &+= 1
        lease.generation = generation
        activeLease = lease
        let scheduledGeneration = generation

        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self else { return }
            await self.resumeIfStillOwned(
                generation: scheduledGeneration,
                resumeAllowed: resumeAllowed
            )
        }
    }

    func releaseForSpeechPause() {
        scheduleResume(after: 0, resumeAllowed: { true })
    }

    func shutdown() {
        resumeTask?.cancel()
        resumeTask = nil
        generation &+= 1
        if let lease = activeLease, !lease.backend.restoreOnShutdown(lease.session) {
            NSLog("%@ could not restore media during shutdown", lease.backend.name)
        }
        activeLease = nil
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

    private func pauseAndVerify(
        _ session: MediaSessionSnapshot,
        with backend: any MediaControlBackend
    ) async -> MediaSessionSnapshot? {
        do {
            guard try await backend.pause(session) else { return nil }
            return await waitForState(false, session: session, backend: backend)
        } catch {
            NSLog("%@ failed to pause media: %@", backend.name, error.localizedDescription)
            return nil
        }
    }

    private func resumeIfStillOwned(
        generation expectedGeneration: UInt64,
        resumeAllowed: @escaping @MainActor () -> Bool
    ) async {
        defer {
            if generation == expectedGeneration {
                resumeTask = nil
            }
        }
        guard generation == expectedGeneration,
              let lease = activeLease,
              lease.generation == expectedGeneration,
              resumeAllowed() else {
            return
        }
        guard let current = await matchingSession(for: lease) else {
            activeLease = nil
            return
        }
        if current.isPlaying {
            activeLease = nil
            return
        }

        do {
            guard try await lease.backend.play(current) else {
                if generation != expectedGeneration {
                    await restorePause(afterStaleResume: current, lease: lease)
                } else {
                    activeLease = nil
                }
                return
            }
        } catch {
            if generation != expectedGeneration || Task.isCancelled {
                await restorePause(afterStaleResume: current, lease: lease)
                return
            }
            NSLog("%@ failed to resume media: %@", lease.backend.name, error.localizedDescription)
            activeLease = nil
            return
        }

        guard generation == expectedGeneration else {
            await restorePause(afterStaleResume: current, lease: lease)
            return
        }
        if !resumeAllowed() {
            await restorePause(afterStaleResume: current, lease: lease)
            return
        }
        guard let playing = await waitForState(true, session: current, backend: lease.backend) else {
            activeLease = nil
            return
        }
        guard generation == expectedGeneration, resumeAllowed() else {
            await restorePause(afterStaleResume: playing, lease: lease)
            return
        }
        activeLease = nil
    }

    private func restorePause(
        afterStaleResume session: MediaSessionSnapshot,
        lease: InterruptionLease
    ) async {
        guard let currentLease = activeLease,
              ObjectIdentifier(currentLease.backend) == ObjectIdentifier(lease.backend),
              currentLease.session.belongsToSameSession(as: session) else {
            return
        }
        let currentGeneration = generation
        if let paused = await pauseAndVerify(session, with: lease.backend) {
            guard generation == currentGeneration,
                  let retainedLease = activeLease,
                  ObjectIdentifier(retainedLease.backend) == ObjectIdentifier(lease.backend),
                  retainedLease.session.belongsToSameSession(as: paused) else {
                return
            }
            activeLease = InterruptionLease(
                generation: generation,
                backend: lease.backend,
                session: paused
            )
        }
    }

    private func matchingSession(for lease: InterruptionLease) async -> MediaSessionSnapshot? {
        do {
            return try await lease.backend.sessions().first {
                $0.belongsToSameSession(as: lease.session)
            }
        } catch {
            NSLog("%@ failed to read media state: %@", lease.backend.name, error.localizedDescription)
            return nil
        }
    }

    private func waitForState(
        _ isPlaying: Bool,
        session: MediaSessionSnapshot,
        backend: any MediaControlBackend
    ) async -> MediaSessionSnapshot? {
        for attempt in 0..<verificationAttempts {
            do {
                if let current = try await backend.sessions().first(where: {
                    $0.belongsToSameSession(as: session)
                }), current.isPlaying == isPlaying {
                    return current
                }
            } catch {
                NSLog("%@ failed to verify media state: %@", backend.name, error.localizedDescription)
                return nil
            }
            if attempt < verificationAttempts - 1 {
                try? await Task.sleep(for: .seconds(verificationDelay))
            }
        }
        return nil
    }
}
