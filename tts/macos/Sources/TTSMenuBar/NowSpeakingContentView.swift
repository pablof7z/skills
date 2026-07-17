import AppKit
import SwiftUI

struct NowSpeakingHUDView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: NowSpeakingPresentation
    @ObservedObject var sessionOpener: AgentSessionOpener
    @ObservedObject var playerPreferencesStore: PlayerPreferencesStore
    @State var questionComposer = QuestionComposerModel()
    @StateObject var answerEditorPresenter = AnswerEditorPresenter()
    @State var isAnswerDropTarget = false
    @State var primaryMessageContentHeight: CGFloat = 150
    @State var previewPlaybackOffset: TimeInterval = 0

    var body: some View {
        if let item = displayedItem {
            let accent = WorkspaceAccent.color(forWorkspacePath: item.workspacePath)
            VStack(alignment: .leading, spacing: 12) {
                if item.isQuestion {
                    questionPrompt(item: item, accent: accent)
                } else {
                    summary(item: item, accent: accent)

                    if isPreviewingPending {
                        Divider().overlay(Color.white.opacity(0.11))
                        ReadAlongTranscriptView(
                            text: item.text,
                            timings: item.wordTimings,
                            currentTime: 0,
                            duration: 0,
                            accent: accent,
                            onSeek: { _ in },
                            attachments: item.briefAttachments,
                            onOpenAttachment: { activateAttachment($0, item: item) }
                        )
                        .transition(.opacity)
                        Divider().overlay(Color.white.opacity(0.11))
                        pendingPreviewStatus(for: item)
                    } else {
                        if !item.briefAttachments.isEmpty {
                            attachmentStrip(item: item, accent: accent)
                        }
                        Divider().overlay(Color.white.opacity(0.11))
                        if let attachment = selectedAttachment(for: item) {
                            attachmentPreview(attachment, item: item, accent: accent)
                                .transition(.opacity)
                        } else {
                            ReadAlongTranscriptView(
                                text: item.text,
                                timings: item.wordTimings,
                                currentTime: playbackTime,
                                duration: playbackDuration,
                                accent: accent,
                                onSeek: { seek(item: item, to: $0) },
                                attachments: item.briefAttachments,
                                onOpenAttachment: { activateAttachment($0, item: item) }
                            )
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        Divider().overlay(Color.white.opacity(0.11))
                        timeline(accent: accent)
                        controls(item: item, accent: accent)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .onHover { presentation.updateHover($0) }
            .onChange(of: item.id) { _ in
                answerEditorPresenter.cancel()
                primaryMessageContentHeight = 150
                previewPlaybackOffset = 0
                questionComposer.reset()
                prepareComposer(for: item)
            }
            .onAppear {
                prepareComposer(for: item)
            }
            .onDisappear { answerEditorPresenter.cancel() }
            .accessibilityLabel(
                "\(isPreviewingPending ? "Pending update" : "Now speaking"). \(item.nowSpeakingTitle). \(item.nowSpeakingContext)"
            )
            .queueAutoplayBlockerBanner(controller.queueAutoplayBlockers)
        } else {
            PlayerQueueView(
                controller: controller,
                presentation: presentation,
                sessionOpener: sessionOpener,
                hiddenItemID: presentation.hiddenItemID,
                historyClock: controller.historyTimestampClock,
                historyRevision: controller.historyRevision,
                generationProgressNow: controller.isGenerating ? controller.generationProgressNow : .distantPast,
                isViewingArchive: presentation.isViewingArchive,
                historyEntityFilters: presentation.historyEntityFilters,
                historySearchQuery: presentation.historySearchQuery,
                historyAgeFilter: presentation.historyAgeFilter,
                hasInteractedWithHistory: presentation.hasInteractedWithHistory
            )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .queueAutoplayBlockerBanner(controller.queueAutoplayBlockers)
        }
    }

}
