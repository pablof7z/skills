import Foundation

@MainActor
extension MediaController {
    func scheduleResume(
        after delay: TimeInterval,
        resumeAllowed: @escaping @MainActor () -> Bool
    ) {
        if resumeTask != nil {
            trace("resume_cancelled", lease: activeLease, reason: "rescheduled")
        }
        resumeTask?.cancel()
        guard var lease = activeLease else {
            trace("resume_not_scheduled", reason: "no_active_lease")
            return
        }
        generation &+= 1
        lease.generation = generation
        activeLease = lease
        let scheduledGeneration = generation
        trace("resume_scheduled", lease: lease, delay: max(0, delay))

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

    func shutdown(reason: String = "app_shutdown") {
        if resumeTask != nil {
            trace("resume_cancelled", lease: activeLease, reason: reason)
        }
        resumeTask?.cancel()
        resumeTask = nil
        generation &+= 1
        guard let lease = activeLease else {
            trace("shutdown_completed", reason: "no_active_lease")
            return
        }
        let restored = lease.backend.restoreOnShutdown(lease.session)
        trace(
            restored ? "lease_released" : "shutdown_restore_failed",
            lease: lease,
            session: lease.session,
            reason: reason
        )
        if !restored {
            NSLog("%@ could not restore media during shutdown", lease.backend.name)
        }
        activeLease = nil
    }

    func resumeIfStillOwned(
        generation expectedGeneration: UInt64,
        resumeAllowed: @escaping @MainActor () -> Bool
    ) async {
        defer {
            if generation == expectedGeneration {
                resumeTask = nil
            }
        }
        guard generation == expectedGeneration else {
            trace("resume_skipped", reason: "stale_generation")
            return
        }
        guard let lease = activeLease else {
            trace("resume_skipped", reason: "no_active_lease")
            return
        }
        guard lease.generation == expectedGeneration else {
            trace("resume_skipped", lease: lease, reason: "lease_generation_changed")
            return
        }
        guard resumeAllowed() else {
            trace("resume_deferred", lease: lease, reason: "queue_not_idle")
            return
        }
        guard let current = await matchingSession(for: lease) else {
            trace("lease_released", lease: lease, reason: "session_missing")
            activeLease = nil
            return
        }
        if current.isPlaying {
            trace("lease_released", lease: lease, session: current, reason: "already_playing")
            activeLease = nil
            return
        }

        trace("resume_requested", lease: lease, session: current)
        do {
            guard try await lease.backend.play(current) else {
                trace("resume_rejected", lease: lease, session: current)
                if generation != expectedGeneration {
                    await restorePause(afterStaleResume: current, lease: lease)
                } else {
                    trace("lease_released", lease: lease, reason: "resume_rejected")
                    activeLease = nil
                }
                return
            }
        } catch {
            trace("resume_failed", lease: lease, session: current, error: error)
            if generation != expectedGeneration || Task.isCancelled {
                await restorePause(afterStaleResume: current, lease: lease)
                return
            }
            NSLog("%@ failed to resume media: %@", lease.backend.name, error.localizedDescription)
            trace("lease_released", lease: lease, reason: "resume_failed")
            activeLease = nil
            return
        }

        guard generation == expectedGeneration else {
            trace("resume_stale", lease: lease, reason: "generation_changed_after_play")
            await restorePause(afterStaleResume: current, lease: lease)
            return
        }
        if !resumeAllowed() {
            trace("resume_stale", lease: lease, reason: "queue_changed_after_play")
            await restorePause(afterStaleResume: current, lease: lease)
            return
        }
        guard let playing = await waitForState(
            true,
            session: current,
            backend: lease.backend,
            lease: lease
        ) else {
            trace("lease_released", lease: lease, reason: "resume_unverified")
            activeLease = nil
            return
        }
        guard generation == expectedGeneration, resumeAllowed() else {
            trace("resume_stale", lease: lease, session: playing, reason: "state_changed_after_verify")
            await restorePause(afterStaleResume: playing, lease: lease)
            return
        }
        trace("lease_released", lease: lease, session: playing, reason: "resume_verified")
        activeLease = nil
    }

    func restorePause(
        afterStaleResume session: MediaSessionSnapshot,
        lease: InterruptionLease
    ) async {
        guard let currentLease = activeLease,
              ObjectIdentifier(currentLease.backend) == ObjectIdentifier(lease.backend),
              currentLease.session.belongsToSameSession(as: session) else {
            trace("stale_resume_ignored", lease: lease, session: session, reason: "ownership_changed")
            return
        }
        trace("restore_pause_requested", lease: currentLease, session: session)
        let currentGeneration = generation
        if let paused = await pauseAndVerify(session, with: lease.backend, lease: currentLease) {
            guard generation == currentGeneration,
                  let retainedLease = activeLease,
                  ObjectIdentifier(retainedLease.backend) == ObjectIdentifier(lease.backend),
                  retainedLease.session.belongsToSameSession(as: paused) else {
                trace("restore_pause_stale", lease: currentLease, session: paused)
                return
            }
            activeLease = InterruptionLease(
                id: retainedLease.id,
                generation: generation,
                itemID: retainedLease.itemID,
                backend: lease.backend,
                session: paused
            )
            trace("lease_retained", lease: activeLease, session: paused, reason: "stale_resume_repaused")
        }
    }
}
