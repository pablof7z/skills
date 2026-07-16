enum PlayerListPolicy {
    static func includes(_ status: PlaybackStatus) -> Bool {
        status == .generating || status == .playing || status == .paused || status.isRecent
    }
}
