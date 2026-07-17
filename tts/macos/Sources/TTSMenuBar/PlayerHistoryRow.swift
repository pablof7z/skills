import Foundation
import SwiftUI

struct PlayerHistoryRow: View {
    let item: TTSItem
    let playbackState: PlayerHistoryPlaybackState?
    let entityFilters: HistoryEntityFilters
    let action: () -> Void
    let onRetry: () -> Void
    let isRetrying: Bool
    let timestampNow: Date
    let onArchive: () -> Void
    let onIdentityFilter: (PlayerIdentitySegment.Role) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            queueItemIndicator
            VStack(alignment: .leading, spacing: 5) {
                Button(action: action) { speechSummary }
                    .buttonStyle(.plain)
                    .disabled(!canOpenSpeech)
                    .opacity(item.status == .generating ? 0.78 : 1)
                    .help(item.status == .generating ? "Open update while audio is generated" : "Play now")
                    .accessibilityLabel(accessibilityLabel)
                identityFilters
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.status == .generating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Generating audio")
            } else if item.status == .failed {
                retryButton
            }
        }
        .padding(.vertical, 5)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.status != .generating {
                Button(role: item.archived ? nil : .destructive, action: onArchive) {
                    Label(
                        item.archived ? "Restore" : "Archive",
                        systemImage: item.archived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                .tint(item.archived ? .accentColor : .red)
            }
        }
    }

    private var speechSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.nowSpeakingTitle)
                    .font(.system(size: 16, weight: item.unheard ? .bold : .semibold))
                    .foregroundStyle(summaryColor)
                    .lineLimit(1)
                if let playbackState {
                    Image(systemName: playbackState.symbolName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WorkspaceAccent.color(forWorkspacePath: item.workspacePath))
                        .help(playbackState.label)
                        .accessibilityLabel(playbackState.label)
                }
                Spacer(minLength: 8)
                if !item.briefAttachments.isEmpty {
                    Label("\(item.briefAttachments.count)", systemImage: "paperclip")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(item.briefAttachments.count) attachments")
                }
                Text(item.timestampLabel(now: timestampNow))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if let previewSummary = item.previewSummary {
                Text(previewSummary)
                    .font(.system(size: 14, weight: item.unheard ? .medium : .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var identityFilters: some View {
        HStack(spacing: 0) {
            let segments = PlayerIdentityPresentation.segments(for: item)
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 { Text(" - ").foregroundStyle(.tertiary) }
                Button { onIdentityFilter(segment.role) } label: {
                    Text(segment.text)
                        .foregroundStyle(segment.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            isSelected(segment.role) ? segment.color.opacity(0.16) : .clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .help("\(isSelected(segment.role) ? "Remove" : "Add") \(segment.role.title.lowercased()) filter")
                .accessibilityLabel("\(isSelected(segment.role) ? "Remove" : "Add") \(segment.text) filter")
            }
        }
        .font(.system(size: 15, weight: item.unheard ? .semibold : .regular))
        .lineLimit(1)
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Group {
                if isRetrying { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(isRetrying)
        .help(isRetrying ? "Retrying synthesis" : "Retry synthesis")
        .accessibilityLabel(isRetrying ? "Retrying synthesis" : "Retry synthesis")
    }

    @ViewBuilder
    private var queueItemIndicator: some View {
        if item.isQuestion {
            QuestionIndicatorView(item: item, accent: .purple, size: .row)
        } else {
            Circle()
                .fill(item.unheard ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .frame(width: 28, height: 28)
        }
    }

    private func isSelected(_ role: PlayerIdentitySegment.Role) -> Bool {
        switch role {
        case .project:
            item.workspaceName.map(entityFilters.projects.contains) == true
        case .agent:
            entityFilters.agents.contains(item.historyAgentFilter)
        }
    }

    private var canOpenSpeech: Bool {
        item.status != .failed
            && (item.status == .generating || FileManager.default.fileExists(atPath: item.outputFile))
    }

    private var summaryColor: Color {
        item.status == .failed ? .secondary : .primary.opacity(0.84)
    }

    private var accessibilityLabel: String {
        let title = item.subjectLabel ?? item.text
        if let playbackState { return "\(playbackState.label). \(title)" }
        if item.isPendingQuestion { return "Answer needed for \(title)" }
        if item.questionStatus == .answered { return "Answered question \(title)" }
        if item.isQuestion { return "Question item \(title)" }
        if item.status == .generating { return "Open pending update \(title)" }
        if item.status == .failed { return "Failed synthesis for \(title)" }
        return "Play now \(title)"
    }
}
