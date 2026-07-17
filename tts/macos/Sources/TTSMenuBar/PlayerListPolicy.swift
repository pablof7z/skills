enum PlayerListPolicy {
    static func includes(
        _ status: PlaybackStatus,
        playbackRequested: Bool? = nil
    ) -> Bool {
        guard playbackRequested != false, status != .generated else { return false }
        return status == .generating || status == .queued || status == .playing
            || status == .paused || status.isRecent
    }
}
