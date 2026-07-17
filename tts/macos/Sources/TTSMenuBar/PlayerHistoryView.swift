import Foundation
import SwiftUI

struct PlayerHistoryView: View {
    let controller: PlaybackController
    let presentation: NowSpeakingPresentation
    @ObservedObject var historyClock: HistoryTimestampClock
    let historyRevision: Int
    let generationProgressNow: Date
    let isViewingArchive: Bool
    let historyEntityFilters: HistoryEntityFilters
    let historySearchQuery: String
    let historyAgeFilter: HistoryAgeFilter
    let hasInteractedWithHistory: Bool

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
                    let playbackState = PlayerHistoryPlaybackState(
                        itemID: item.id,
                        currentItemID: controller.currentItemID,
                        status: item.status
                    )
                    let generationProgress = item.status == .generating
                        ? controller.generationProgress(for: item)
                        : 0
                    PlayerHistoryRow(
                        item: item,
                        playbackState: playbackState,
                        entityFilters: historyEntityFilters,
                        action: {
                            presentation.registerHistoryInteraction()
                            presentation.revealForDirectSelection(itemID: item.id)
                            if item.status == .generating || item.isPendingQuestion {
                                presentation.previewPendingItem(item)
                            } else {
                                controller.playNow(item)
                            }
                        },
                        onRetry: { controller.retryGeneration(item) },
                        isRetrying: controller.isRetrying(item),
                        timestampNow: historyClock.now,
                        onArchive: {
                            presentation.registerHistoryInteraction()
                            controller.setArchived(!item.archived, for: item)
                        },
                        onIdentityFilter: { role in
                            switch role {
                            case .project:
                                if let project = item.workspaceName {
                                    presentation.toggleHistoryProject(project)
                                }
                            case .agent:
                                presentation.toggleHistoryAgent(item.historyAgentFilter)
                            }
                        }
                    )
                        .listRowInsets(EdgeInsets(
                            top: 8,
                            leading: 16,
                            bottom: item.status == .generating ? 0 : 8,
                            trailing: 16
                        ))
                        .listRowSeparator(item.status == .generating ? .hidden : .visible)
                        .listRowBackground(
                            HistoryRowBackground(
                                item: item,
                                progress: generationProgress,
                                playbackState: playbackState
                            )
                        )
                }
                .listStyle(.plain)
            }
        }
    }

    private var filteredItems: [TTSItem] {
        PlayerHistoryFilterPolicy.filteredItems(
            in: controller.playerListItems,
            query: PlayerHistoryQuery(
                isViewingArchive: isViewingArchive,
                entityFilters: historyEntityFilters,
                ageFilter: historyAgeFilter,
                hasInteractedWithHistory: hasInteractedWithHistory,
                searchQuery: historySearchQuery,
                now: historyClock.now
            )
        )
    }

    private var emptyStateTitle: String {
        if !historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching speech"
        }
        if isViewingArchive {
            return historyEntityFilters.isEmpty ? "No archived speech" : "No archived speech for these filters"
        }
        return historyEntityFilters.isEmpty ? "No recent speech" : "No speech for these filters"
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
            && lhs.historyEntityFilters == rhs.historyEntityFilters
            && lhs.historySearchQuery == rhs.historySearchQuery
            && lhs.historyAgeFilter == rhs.historyAgeFilter
            && lhs.hasInteractedWithHistory == rhs.hasInteractedWithHistory
    }
}

private struct HistoryRowBackground: View {
    let item: TTSItem
    let progress: Double
    let playbackState: PlayerHistoryPlaybackState?

    var body: some View {
        if playbackState != nil {
            ZStack(alignment: .leading) {
                WorkspaceAccent.color(forWorkspacePath: item.workspacePath).opacity(0.12)
                Rectangle()
                    .fill(WorkspaceAccent.color(forWorkspacePath: item.workspacePath))
                    .frame(width: 3)
            }
            .accessibilityHidden(true)
        } else if item.isPendingQuestion {
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
