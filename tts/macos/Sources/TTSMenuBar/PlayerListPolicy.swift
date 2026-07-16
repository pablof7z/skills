enum PlayerListPolicy {
    static func includes(_ status: PlaybackStatus) -> Bool {
        status == .generating || status == .queued || status == .playing
            || status == .paused || status.isRecent
    }
}
