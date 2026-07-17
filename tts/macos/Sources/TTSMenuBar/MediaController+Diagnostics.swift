import Foundation

@MainActor
extension MediaController {
    func trace(
        _ event: String,
        itemID: String? = nil,
        lease: InterruptionLease? = nil,
        leaseID: UUID? = nil,
        backend: (any MediaControlBackend)? = nil,
        session: MediaSessionSnapshot? = nil,
        desiredPlaying: Bool? = nil,
        attempt: Int? = nil,
        delay: TimeInterval? = nil,
        reason: String? = nil,
        error: Error? = nil
    ) {
        logger.record(MediaInterventionRecord(
            event: event,
            generation: generation,
            itemID: itemID ?? lease?.itemID,
            leaseID: leaseID ?? lease?.id,
            backend: backend?.name ?? lease?.backend.name,
            session: session.map(MediaInterventionSession.init),
            desiredPlaying: desiredPlaying,
            attempt: attempt,
            delaySeconds: delay,
            reason: reason,
            error: error?.localizedDescription
        ))
    }
}
