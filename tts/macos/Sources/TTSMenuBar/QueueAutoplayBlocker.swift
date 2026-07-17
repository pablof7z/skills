import Foundation

enum QueueAutoplayBlocker: String, CaseIterable, Identifiable, Sendable {
    case globalPause
    case systemOutputMuted
    case visibleAsk

    var id: Self { self }

    var symbol: String {
        switch self {
        case .globalPause: "pause.circle.fill"
        case .systemOutputMuted: "speaker.slash.circle.fill"
        case .visibleAsk: "questionmark.bubble.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .globalPause: "Global pause"
        case .systemOutputMuted: "Output muted"
        case .visibleAsk: "Ask awaiting answer"
        }
    }

    var detail: String {
        switch self {
        case .globalPause:
            "Queued speech will wait until global playback resumes."
        case .systemOutputMuted:
            "Queued speech will wait until Mac output is unmuted."
        case .visibleAsk:
            "Queued speech will wait while the open question needs an answer."
        }
    }
}

enum QueueAutoplayBlockerPolicy {
    static func blockers(
        isGloballyPaused: Bool,
        isSystemOutputMuted: Bool,
        visibleAskQueueHoldID: String?
    ) -> [QueueAutoplayBlocker] {
        var blockers: [QueueAutoplayBlocker] = []
        if isGloballyPaused { blockers.append(.globalPause) }
        if isSystemOutputMuted { blockers.append(.systemOutputMuted) }
        if visibleAskQueueHoldID != nil { blockers.append(.visibleAsk) }
        return blockers
    }

    static func summary(_ blockers: [QueueAutoplayBlocker]) -> String {
        blockers.map(\.shortLabel).joined(separator: ", ")
    }
}

struct MenuBarPlaybackState: Equatable {
    let symbol: String
    let label: String
}

extension MenuBarPresentation {
    static func playbackState(
        blockers: [QueueAutoplayBlocker],
        hasCurrentItem: Bool,
        isGenerating: Bool
    ) -> MenuBarPlaybackState {
        if let primaryBlocker = blockers.first {
            return MenuBarPlaybackState(
                symbol: primaryBlocker.symbol,
                label: "Autoplay blocked: \(QueueAutoplayBlockerPolicy.summary(blockers))"
            )
        }
        if hasCurrentItem {
            return MenuBarPlaybackState(symbol: "waveform.circle.fill", label: "TTS playing")
        }
        if isGenerating {
            return MenuBarPlaybackState(symbol: "ellipsis.circle", label: "TTS generating")
        }
        return MenuBarPlaybackState(symbol: "speaker.wave.2", label: "TTS idle")
    }
}
