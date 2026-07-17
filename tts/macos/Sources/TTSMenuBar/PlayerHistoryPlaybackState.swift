enum PlayerHistoryPlaybackState: Equatable {
    case playing
    case paused

    init?(itemID: String, currentItemID: String?, status: PlaybackStatus) {
        guard itemID == currentItemID else { return nil }
        switch status {
        case .playing:
            self = .playing
        case .paused:
            self = .paused
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .playing: "Currently playing"
        case .paused: "Playback paused"
        }
    }

    var symbolName: String {
        switch self {
        case .playing: "speaker.wave.2.fill"
        case .paused: "pause.fill"
        }
    }
}
