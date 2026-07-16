import SwiftUI

struct PlayerQueueView: View {
    @ObservedObject var controller: PlaybackController
    let presentation: NowSpeakingPresentation
    let hiddenItemID: String?
    @ObservedObject var historyClock: HistoryTimestampClock
    let historyRevision: Int
    let generationProgressNow: Date
    let isViewingArchive: Bool
    let historyProjectFilter: String?
    let historySearchQuery: String

    var body: some View {
        PlayerHistoryView(
            controller: controller,
            presentation: presentation,
            historyClock: historyClock,
            historyRevision: historyRevision,
            generationProgressNow: generationProgressNow,
            isViewingArchive: isViewingArchive,
            historyProjectFilter: historyProjectFilter,
            historySearchQuery: historySearchQuery
        )
        .equatable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let item = miniPlayerItem {
                QueueMiniPlayer(
                    controller: controller,
                    item: item,
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
            && lhs.hiddenItemID == rhs.hiddenItemID
            && lhs.historyClock === rhs.historyClock
            && lhs.historyRevision == rhs.historyRevision
            && lhs.generationProgressNow == rhs.generationProgressNow
            && lhs.isViewingArchive == rhs.isViewingArchive
            && lhs.historyProjectFilter == rhs.historyProjectFilter
            && lhs.historySearchQuery == rhs.historySearchQuery
    }
}

private struct QueueMiniPlayer: View {
    @ObservedObject var controller: PlaybackController
    let item: TTSItem
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
                Button(action: showFullPlayer) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 30, height: 30)
                            .background(accent.opacity(0.14), in: Circle())

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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Open full player")
                .accessibilityLabel("Open full player for \(item.nowSpeakingTitle)")

                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                controlButton(symbol: "gobackward.15", label: "Back 15 seconds") {
                    controller.rewind()
                }
                controlButton(
                    symbol: controller.isPaused ? "play.fill" : "pause.fill",
                    label: controller.isPaused ? "Resume" : "Pause",
                    prominent: true
                ) {
                    controller.togglePause()
                }
                controlButton(symbol: "goforward.15", label: "Forward 15 seconds") {
                    controller.forward()
                }
                controlButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open full player") {
                    showFullPlayer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini player for \(item.nowSpeakingTitle), \(timeLabel)")
    }

    private var accent: Color {
        WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
    }

    private var timeLabel: String {
        "\(formatted(controller.currentTime)) / \(formatted(controller.duration))"
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

    private func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
