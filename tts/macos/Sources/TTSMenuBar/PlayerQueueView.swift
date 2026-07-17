import SwiftUI

struct PlayerQueueView: View {
    @ObservedObject var controller: PlaybackController
    let presentation: NowSpeakingPresentation
    @ObservedObject var sessionOpener: AgentSessionOpener
    let hiddenItemID: String?
    @ObservedObject var historyClock: HistoryTimestampClock
    let historyRevision: Int
    let generationProgressNow: Date
    let isViewingArchive: Bool
    let historyProjectFilter: String?
    let historySearchQuery: String
    let historyAgeFilter: HistoryAgeFilter
    let hasInteractedWithHistory: Bool

    var body: some View {
        PlayerHistoryView(
            controller: controller,
            presentation: presentation,
            historyClock: historyClock,
            historyRevision: historyRevision,
            generationProgressNow: generationProgressNow,
            isViewingArchive: isViewingArchive,
            historyProjectFilter: historyProjectFilter,
            historySearchQuery: historySearchQuery,
            historyAgeFilter: historyAgeFilter,
            hasInteractedWithHistory: hasInteractedWithHistory
        )
        .equatable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let item = miniPlayerItem {
                QueueMiniPlayer(
                    controller: controller,
                    item: item,
                    sessionOpener: sessionOpener,
                    showFullPlayer: {
                        presentation.revealForDirectSelection(itemID: item.id)
                    }
                )
            }
        }
    }

    private var miniPlayerItem: TTSItem? {
        guard PlayerNavigationPolicy.shouldShowMiniPlayer(
            currentItemID: controller.currentItem?.id,
            hiddenItemID: hiddenItemID
        ) else { return nil }
        return controller.currentItem
    }
}

extension PlayerQueueView: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.controller === rhs.controller
            && lhs.presentation === rhs.presentation
            && lhs.sessionOpener === rhs.sessionOpener
            && lhs.hiddenItemID == rhs.hiddenItemID
            && lhs.historyClock === rhs.historyClock
            && lhs.historyRevision == rhs.historyRevision
            && lhs.generationProgressNow == rhs.generationProgressNow
            && lhs.isViewingArchive == rhs.isViewingArchive
            && lhs.historyProjectFilter == rhs.historyProjectFilter
            && lhs.historySearchQuery == rhs.historySearchQuery
            && lhs.historyAgeFilter == rhs.historyAgeFilter
            && lhs.hasInteractedWithHistory == rhs.hasInteractedWithHistory
    }
}

private struct QueueMiniPlayer: View {
    @ObservedObject var controller: PlaybackController
    let item: TTSItem
    @ObservedObject var sessionOpener: AgentSessionOpener
    let showFullPlayer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0 ... max(controller.duration, 1)
            )
            .tint(accent)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Playback position")

            HStack(spacing: 12) {
                controlButton(symbol: "xmark", label: "Stop playback") {
                    controller.stop()
                }

                Button(action: showFullPlayer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.nowSpeakingTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.nowSpeakingContext)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Open full player")
                .accessibilityLabel("Open full player for \(item.nowSpeakingTitle)")

                Text(remainingTimeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                playbackRateSelector

                if sessionOpener.canOpen(rawIdentifier: item.iTermSessionID) {
                    controlButton(symbol: "arrow.up.forward.app", label: "Jump to terminal") {
                        sessionOpener.open(rawIdentifier: item.iTermSessionID)
                    }
                }

                controlButton(
                    symbol: controller.isPaused ? "play.fill" : "pause.fill",
                    label: controller.isPaused ? "Resume" : "Pause",
                    prominent: true
                ) {
                    controller.togglePause()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini player for \(item.nowSpeakingTitle), \(remainingTimeLabel) remaining")
    }

    private var accent: Color {
        WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
    }

    private var remainingTimeLabel: String {
        QueueMiniPlayerPresentation.remainingTimeLabel(
            duration: controller.duration,
            currentTime: controller.currentTime
        )
    }

    private var playbackRateSelector: some View {
        Menu {
            ForEach(VoicePlaybackRateStore.availableRates, id: \.self) { rate in
                Button {
                    controller.setPlaybackRate(rate, for: item)
                } label: {
                    if abs(rate - controller.playbackRate) < 0.001 {
                        Label(VoicePlaybackRateStore.label(for: rate), systemImage: "checkmark")
                    } else {
                        Text(VoicePlaybackRateStore.label(for: rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(controller.playbackRateLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(accent)
            .frame(height: 30)
            .padding(.horizontal, 8)
            .background(accent.opacity(0.14), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .help("Choose playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(controller.playbackRateLabel)
    }

    private func controlButton(
        symbol: String,
        label: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 14 : 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.82) : Color.primary)
                .frame(width: prominent ? 34 : 30, height: prominent ? 34 : 30)
                .background(prominent ? accent : Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

}

enum QueueMiniPlayerPresentation {
    static func remainingTimeLabel(duration: TimeInterval, currentTime: TimeInterval) -> String {
        "-\(formatted(max(0, duration - currentTime)))"
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
