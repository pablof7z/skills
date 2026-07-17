import SwiftUI

extension NowSpeakingHUDView {
    func timeline(accent: Color) -> some View {
        VStack(spacing: 3) {
            Slider(
                value: Binding(
                    get: { playbackTime },
                    set: { newValue in
                        if isPreviewingPending {
                            previewPlaybackOffset = newValue
                        } else if isLingering {
                            presentation.lingeringTime = newValue
                        } else {
                            controller.seek(to: newValue)
                        }
                    }
                ),
                in: 0 ... max(playbackDuration, 1),
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    if isPreviewingPending, let item = pendingPreviewItem {
                        controller.replay(item, startingAt: previewPlaybackOffset)
                    } else if isLingering, let item = presentation.lingeringItem {
                        controller.replay(item, startingAt: presentation.lingeringTime)
                    }
                }
            )
            .tint(accent)
            .controlSize(.small)
            .accessibilityLabel("Playback position")

            HStack {
                Text(formattedTime(playbackTime))
                Spacer()
                Text("-" + formattedTime(max(0, playbackDuration - playbackTime)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    func controls(item: TTSItem, accent: Color) -> some View {
        playbackControls(item: item, accent: accent) {
            nextInQueueIndicator
        }
    }

    func playbackControls<Trailing: View>(
        item: TTSItem,
        accent: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                playbackRateButton(item: item, accent: accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                controlButton(symbol: "gobackward.15", label: "Back 15 seconds", accent: accent) {
                    if isLingering || isPreviewingPending {
                        controller.replay(item, startingAt: max(0, playbackTime - 15))
                    } else {
                        controller.rewind()
                    }
                }
                controlButton(
                    symbol: isLingering || isPreviewingPending
                        ? "arrow.counterclockwise"
                        : (controller.isPaused ? "play.fill" : "pause.fill"),
                    label: isLingering || isPreviewingPending
                        ? "Replay"
                        : (controller.isPaused ? "Resume" : "Pause"),
                    accent: accent,
                    prominent: true
                ) {
                    if isLingering || isPreviewingPending {
                        controller.replay(item, startingAt: 0)
                    } else {
                        controller.togglePause()
                    }
                }
                controlButton(symbol: "goforward.15", label: "Forward 15 seconds", accent: accent) {
                    if isLingering || isPreviewingPending {
                        controller.replay(
                            item,
                            startingAt: min(playbackDuration, playbackTime + 15)
                        )
                    } else {
                        controller.forward()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    var nextInQueueIndicator: some View {
        if let next = controller.nextQueuedItem {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("UP NEXT")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(.tertiary)
                    Text(next.nowSpeakingTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .help("Next: \(next.nowSpeakingTitle)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Up next: \(next.nowSpeakingTitle)")
        } else {
            Color.clear
                .frame(height: 34)
                .accessibilityHidden(true)
        }
    }

    func playbackRateButton(item: TTSItem, accent: Color) -> some View {
        Button {
            controller.cyclePlaybackRate(for: item)
        } label: {
            Text(controller.playbackRateLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 42, height: 34)
                .background(accent.opacity(0.14), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(accent.opacity(0.28), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .help("Playback speed for \(item.voice). Click to change.")
        .accessibilityLabel("Playback speed for \(item.voice)")
        .accessibilityValue(controller.playbackRateLabel)
    }

    func controlButton(
        symbol: String,
        label: String,
        accent: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 15, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.82) : Color.primary)
                .frame(width: prominent ? 38 : 34, height: prominent ? 38 : 34)
                .background(
                    prominent ? accent : Color.white.opacity(0.09),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    var progress: Double {
        guard playbackDuration > 0 else { return 0 }
        return min(max(playbackTime / playbackDuration, 0), 1)
    }

    var displayedItem: TTSItem? {
        let item = controller.currentItem ?? pendingPreviewItem ?? presentation.lingeringItem
        guard PlayerNavigationPolicy.shouldDisplay(
            itemID: item?.id,
            hiddenItemID: presentation.hiddenItemID
        ) else { return nil }
        return item
    }

    var pendingPreviewItem: TTSItem? {
        guard let preview = presentation.pendingPreviewItem else { return nil }
        return controller.items.first(where: { $0.id == preview.id }) ?? preview
    }

    var isPreviewingPending: Bool {
        controller.currentItem == nil && pendingPreviewItem != nil
    }

    var isLingering: Bool {
        controller.currentItem == nil && presentation.lingeringItem != nil
    }

    var playbackTime: TimeInterval {
        if isPreviewingPending { return previewPlaybackOffset }
        return isLingering ? presentation.lingeringTime : controller.currentTime
    }

    var playbackDuration: TimeInterval {
        if isPreviewingPending { return pendingPreviewItem?.duration ?? 0 }
        return isLingering ? presentation.lingeringDuration : controller.duration
    }

    var statusSymbol: String {
        if isPreviewingPending {
            return pendingPreviewItem?.status == .generating ? "ellipsis" : "clock"
        }
        if isLingering { return "arrow.counterclockwise" }
        return controller.isPaused ? "pause.fill" : "waveform"
    }

    func seek(item: TTSItem, to time: TimeInterval) {
        if isLingering || isPreviewingPending {
            controller.replay(item, startingAt: time)
        } else {
            controller.seek(to: time)
        }
    }

    func formattedTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
