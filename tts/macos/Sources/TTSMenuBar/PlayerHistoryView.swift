import Foundation
import SwiftUI

struct PlayerHistoryView: View {
    let controller: PlaybackController
    let presentation: NowSpeakingPresentation
    @ObservedObject var historyClock: HistoryTimestampClock
    let historyRevision: Int
    let generationProgressNow: Date
    let isViewingArchive: Bool
    let historyProjectFilter: String?
    let historySearchQuery: String

    var body: some View {
        Group {
            if filteredItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(emptyStateTitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredItems.prefix(60)) { item in
                    let generationProgress = item.status == .generating
                        ? controller.generationProgress(for: item)
                        : 0
                    PlayerHistoryRow(
                        item: item,
                        action: {
                            presentation.revealForDirectSelection(itemID: item.id)
                            if item.status == .generating || item.isPendingQuestion {
                                presentation.previewPendingItem(item)
                            } else {
                                controller.playNow(item)
                            }
                        },
                        onRetry: { controller.retryGeneration(item) },
                        isRetrying: controller.isRetrying(item),
                        generationProgress: generationProgress,
                        timestampNow: historyClock.now,
                        onArchive: { controller.setArchived(!item.archived, for: item) }
                    )
                        .listRowInsets(EdgeInsets(
                            top: 8,
                            leading: 16,
                            bottom: item.status == .generating ? 0 : 8,
                            trailing: 16
                        ))
                        .listRowSeparator(item.status == .generating ? .hidden : .visible)
                        .listRowBackground(
                            GenerationProgressRowBackground(
                                item: item,
                                progress: generationProgress
                            )
                        )
                }
                .listStyle(.plain)
            }
        }
    }

    private var historyItems: [TTSItem] {
        isViewingArchive ? controller.archivedHistoryItems : controller.activeHistoryItems
    }

    private var filteredItems: [TTSItem] {
        historyItems.filter { item in
            let matchesProject = historyProjectFilter.map { item.workspaceName == $0 } ?? true
            return matchesProject && matchesSearch(item)
        }
    }

    private var emptyStateTitle: String {
        if !historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching speech"
        }
        if isViewingArchive {
            return historyProjectFilter == nil ? "No archived speech" : "No archived speech for this project"
        }
        return historyProjectFilter == nil ? "No recent speech" : "No speech for this project"
    }

    private func matchesSearch(_ item: TTSItem) -> Bool {
        let query = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [item.nowSpeakingTitle, item.text, item.displayAgent, item.workspaceName]
            .compactMap(\.self)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension PlayerHistoryView: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.controller === rhs.controller
            && lhs.presentation === rhs.presentation
            && lhs.historyClock === rhs.historyClock
            && lhs.historyRevision == rhs.historyRevision
            && lhs.generationProgressNow == rhs.generationProgressNow
            && lhs.isViewingArchive == rhs.isViewingArchive
            && lhs.historyProjectFilter == rhs.historyProjectFilter
            && lhs.historySearchQuery == rhs.historySearchQuery
    }
}

private struct PlayerHistoryRow: View {
    let item: TTSItem
    let action: () -> Void
    let onRetry: () -> Void
    let isRetrying: Bool
    let generationProgress: Double
    let timestampNow: Date
    let onArchive: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            queueItemIndicator
            Button(action: action) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.nowSpeakingTitle)
                            .font(.system(size: 16, weight: item.unheard ? .bold : .semibold))
                            .foregroundStyle(summaryColor)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.timestampLabel(now: timestampNow))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 0) {
                        let segments = PlayerIdentityPresentation.segments(for: item)
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 {
                                Text(" - ")
                                    .foregroundStyle(.tertiary)
                            }
                            Text(segment.text)
                                .foregroundStyle(segment.color)
                        }
                    }
                    .font(.system(size: 15, weight: item.unheard ? .semibold : .regular))
                    .lineLimit(1)
                }

                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.status == .failed || (item.status != .generating && !FileManager.default.fileExists(atPath: item.outputFile)))
            .opacity(item.status == .generating ? 0.78 : 1)
            .help(item.status == .generating ? "Open update while audio is generated" : "Play now")
            .accessibilityLabel(accessibilityLabel)

            if item.status == .generating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Generating audio")
            } else {
                VStack(alignment: .trailing, spacing: 7) {
                    if item.status == .failed {
                        Button(action: onRetry) {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 18, height: 18)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isRetrying)
                        .help(isRetrying ? "Retrying synthesis" : "Retry synthesis")
                        .accessibilityLabel(isRetrying ? "Retrying synthesis" : "Retry synthesis")
                    }
                }
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

    @ViewBuilder
    private var queueItemIndicator: some View {
        if item.isPendingQuestion {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.orange, in: Circle())
                .shadow(color: Color.orange.opacity(0.28), radius: 4, y: 1)
                .help("Contains unanswered questions")
                .accessibilityLabel("Unanswered questions")
        } else if item.isQuestion {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(Color.purple.opacity(0.12), in: Circle())
                .help("Contains questions")
                .accessibilityLabel("Contains questions")
        } else {
            Circle()
                .fill(item.unheard ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .frame(width: 28, height: 28)
        }
    }

    private var summaryColor: Color {
        item.status == .failed ? .secondary : .primary.opacity(0.84)
    }

    private var accessibilityLabel: String {
        let title = item.subjectLabel ?? item.text
        if item.isPendingQuestion { return "Answer needed for \(title)" }
        if item.isQuestion { return "Question item \(title)" }
        if item.status == .generating { return "Open pending update \(title)" }
        if item.status == .failed { return "Failed synthesis for \(title)" }
        return "Play now \(title)"
    }
}

private struct GenerationProgressRowBackground: View {
    let item: TTSItem
    let progress: Double

    var body: some View {
        if item.isPendingQuestion {
            Color.orange.opacity(0.075)
                .accessibilityHidden(true)
        } else if item.status == .generating {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.10))
                        Rectangle()
                            .fill(WorkspaceAccent.color(forWorkspacePath: item.workspacePath).opacity(0.82))
                            .frame(width: max(3, (geometry.size.width - 17) * progress))
                    }
                    .frame(height: 2)
                    .padding(.leading, 17)
                }
            }
            .accessibilityLabel("Generating audio")
        } else {
            Color.clear
        }
    }
}
