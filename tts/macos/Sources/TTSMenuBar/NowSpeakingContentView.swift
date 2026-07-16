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
                            onSeek: { _ in }
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
                                onSeek: { seek(item: item, to: $0) }
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
        } else {
            PlayerQueueView(
                controller: controller,
                presentation: presentation,
                hiddenItemID: presentation.hiddenItemID,
                historyClock: controller.historyTimestampClock,
                historyRevision: controller.historyRevision,
                generationProgressNow: controller.isGenerating ? controller.generationProgressNow : .distantPast,
                isViewingArchive: presentation.isViewingArchive,
                historyProjectFilter: presentation.historyProjectFilter,
                historySearchQuery: presentation.historySearchQuery
            )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    func questionPrompt(item: TTSItem, accent: Color) -> some View {
        let questions = displayQuestions(for: item)
        let current = selectedQuestion(in: questions)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                QuestionIndicatorView(item: item, accent: accent, size: .header)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.subjectLabel ?? "Questions from \(item.displayAgent)")
                        .font(.headline)
                    Text([item.displayAgent, item.workspaceDisplayLabel].compactMap(\.self).joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if sessionOpener.canOpen(rawIdentifier: item.iTermSessionID) {
                    Button {
                        sessionOpener.open(rawIdentifier: item.iTermSessionID)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open agent session")
                    .accessibilityLabel("Open agent session")
                }

            }

            if let primaryMessage = item.primaryMessage?.nonemptyValue {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Update")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ReadAlongTranscriptView(
                        text: primaryMessage,
                        timings: item.wordTimings,
                        currentTime: playbackTime,
                        duration: playbackDuration,
                        accent: accent,
                        onSeek: { seek(item: item, to: $0) },
                        onContentHeightChange: { height in
                            guard abs(primaryMessageContentHeight - height) > 1 else { return }
                            primaryMessageContentHeight = height
                        }
                    )
                    .frame(height: min(max(primaryMessageContentHeight, 72), 420))
                    .accessibilityLabel("Primary message")
                }
            }

            if !item.briefAttachments.isEmpty {
                contextAttachmentRow(
                    item.briefAttachments,
                    label: "Update attachments",
                    item: item,
                    accent: accent
                )
            }

            if questions.count > 1 {
                questionTabs(questions, accent: accent)
            }

            if let question = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(question.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            if let description = question.description?.nonemptyValue {
                                Text(description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let attachments = question.attachments, !attachments.isEmpty {
                            contextAttachmentRow(
                                attachments,
                                label: "Question context",
                                item: item,
                                accent: accent
                            )
                        }

                        if question.status == .pending, item.isPendingQuestion {
                            pendingQuestionContent(question, item: item, accent: accent)
                        } else if let response = question.response {
                            sentResponse(response, accent: accent)
                        } else if question.status == .skipped {
                            Label("Skipped", systemImage: "forward.end.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Question \(question.title)")
            }

            if item.isPendingQuestion {
                HStack(spacing: 10) {
                    Text("All questions are optional. Blanks will be skipped.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        submitAnswers(for: item, questions: questions)
                    } label: {
                        Label(questions.count > 1 ? "Send answers" : "Send", systemImage: "arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit(item: item, questions: questions))
                    .opacity(canSubmit(item: item, questions: questions) ? 1 : 0.45)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityHint("Submits every tab together; unanswered questions are skipped")
                }
            }

            if !isPreviewingPending || QuestionAudioReview.canReplay(item) {
                Divider().overlay(Color.white.opacity(0.11))
                timeline(accent: accent)
                controls(item: item, accent: accent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from \(item.displayAgent)")
    }

    @ViewBuilder
    func pendingQuestionContent(
        _ question: TTSQuestion,
        item: TTSItem,
        accent: Color
    ) -> some View {
        let draft = questionComposer.draft(for: question.id)
        if let suggestions = question.suggestions, !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(question.type == .multipleChoice ? "Choose any that apply" : "Choose one")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    suggestionCard(
                        suggestion,
                        id: suggestionID(suggestion, index: index),
                        question: question,
                        item: item,
                        selected: draft.selectedSuggestionIDs.contains(suggestionID(suggestion, index: index)),
                        accent: accent
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggested answers")
        }

        let answerAttachments = questionComposer.draft(for: question.id).attachmentURLs
        VStack(alignment: .leading, spacing: 6) {
            Text(question.type == .multipleChoice ? "Additional note" : "Your answer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 6) {
                Button {
                    openAnswerEditor(for: question)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(draft.freeformText.nonemptyValue ?? "Write anything…")
                            .font(.system(size: 15))
                            .foregroundStyle(draft.freeformText.nonemptyValue == nil ? .secondary : .primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open answer editor for \(question.title)")

                Button {
                    questionComposer.addAttachments(pickFiles(), for: question.id)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help("Attach files")
                .accessibilityLabel("Attach files to this answer")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                isAnswerDropTarget ? accent.opacity(0.11) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        isAnswerDropTarget ? accent : accent.opacity(0.22),
                        lineWidth: isAnswerDropTarget ? 1.4 : 0.8
                    )
            }
            .overlay(alignment: .bottomLeading) {
                if isAnswerDropTarget {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                questionComposer.addAttachments(files, for: question.id)
                return !files.isEmpty
            } isTargeted: { isAnswerDropTarget = $0 }
            .accessibilityLabel("Freeform answer for \(question.title)")

            if !answerAttachments.isEmpty {
                answerAttachmentChips(
                    answerAttachments,
                    questionID: question.id,
                    suggestionID: nil,
                    accent: accent
                )
            }
        }
    }

}
