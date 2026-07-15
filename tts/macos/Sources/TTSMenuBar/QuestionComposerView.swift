import AppKit
import SwiftUI

extension NowSpeakingHUDView {
    func questionTabs(_ questions: [TTSQuestion], accent: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    let selected = questionComposer.selectedQuestionID == question.id
                    let answered = !questionComposer.submissions(questionIDs: [question.id])[0].isSkipped
                    Button {
                        questionComposer.selectQuestion(question.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .frame(width: 18, height: 18)
                                .background(selected ? Color.black.opacity(0.16) : accent.opacity(0.13), in: Circle())
                            Text(question.shortTitle?.nonemptyValue ?? question.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if answered {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.primary)
                        .background(
                            selected ? accent : Color.white.opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Question \(index + 1): \(question.title)")
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("Question tabs")
    }

    func suggestionCard(
        _ suggestion: TTSSuggestion,
        id: String,
        question: TTSQuestion,
        item: TTSItem,
        selected: Bool,
        accent: Color
    ) -> some View {
        let draft = questionComposer.draft(for: question.id)
        let suggestionDraft = draft.suggestion(id)
        let displayTitle = suggestionDraft?.isEdited == true
            ? suggestionDraft?.title ?? suggestion.title
            : suggestion.title
        let displayDescription = suggestionDraft?.isEdited == true
            ? suggestionDraft?.description
            : suggestion.description
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    questionComposer.selectSuggestion(
                        id: id,
                        title: displayTitle,
                        description: displayDescription,
                        for: question.id
                    )
                } label: {
                    Image(systemName: choiceSymbol(for: question.type, selected: selected))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? accent : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(question.type == .multipleChoice && selected ? "Deselect" : "Select") \(displayTitle)"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = displayDescription?.nonemptyValue {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay {
                    ImmediateClickTarget(
                        onSingleClick: {
                            questionComposer.selectSuggestion(
                                id: id,
                                title: displayTitle,
                                description: displayDescription,
                                for: question.id
                            )
                        },
                        onDoubleClick: {
                            openSuggestionEditor(suggestion, id: id, questionID: question.id)
                        }
                    )
                }

                Button {
                    openSuggestionEditor(suggestion, id: id, questionID: question.id)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Personalize this suggestion")
                .accessibilityLabel("Personalize \(displayTitle)")
            }

            if let attachments = suggestion.attachments, !attachments.isEmpty {
                compactAttachmentButtons(attachments, item: item, accent: accent)
            }

            if let suggestionDraft, suggestionDraft.isEdited, !suggestionDraft.attachmentURLs.isEmpty {
                answerAttachmentChips(
                    suggestionDraft.attachmentURLs,
                    questionID: question.id,
                    suggestionID: id,
                    accent: accent
                )
            }
        }
        .padding(11)
        .background(
            selected ? accent.opacity(0.16) : Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? accent : accent.opacity(0.14), lineWidth: selected ? 1.2 : 0.7)
        }
        .accessibilityLabel(displayTitle)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(
            question.type == .multipleChoice
                ? "Click to toggle this option. Double-click or use the pencil to personalize."
                : "Click to select without changing the freeform answer. Double-click or use the pencil to personalize."
        )
    }

    func answerAttachmentChips(
        _ urls: [URL],
        questionID: String,
        suggestionID: String?,
        accent: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(urls, id: \.standardizedFileURL.path) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                        Button {
                            if let suggestionID {
                                questionComposer.removeEditedSuggestionAttachment(
                                    url,
                                    suggestionID: suggestionID,
                                    for: questionID
                                )
                            } else {
                                questionComposer.removeAttachment(url, for: questionID)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.1), in: Capsule())
                }
            }
            .padding(.vertical, 1)
        }
    }

    func contextAttachmentRow(
        _ attachments: [TTSAttachment],
        label: String,
        item: TTSItem,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            compactAttachmentButtons(attachments, item: item, accent: accent)
        }
    }

    func compactAttachmentButtons(
        _ attachments: [TTSAttachment],
        item: TTSItem,
        accent: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    Button {
                        openSupportingAttachment(attachment, item: item)
                    } label: {
                        Label(attachment.label, systemImage: attachmentSymbol(attachment))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help(attachmentHelp(attachment))
                }
            }
            .padding(.vertical, 1)
        }
    }

    func sentResponse(_ response: TTSResponse, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Answer sent")
                    .font(.subheadline.weight(.semibold))
                if let answer = response.answer.nonemptyValue {
                    Text(answer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let attachments = response.attachments, !attachments.isEmpty {
                    ForEach(attachments) { attachment in
                        Label(attachment.sourceFile, systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    func displayQuestions(for item: TTSItem) -> [TTSQuestion] {
        if let questions = item.questions, !questions.isEmpty { return questions }
        return [TTSQuestion(
            id: "legacy::\(item.id)",
            title: item.text,
            suggestions: item.suggestions,
            status: item.questionStatus ?? .pending,
            response: item.response
        )]
    }

    func selectedQuestion(in questions: [TTSQuestion]) -> TTSQuestion? {
        let selected = questionComposer.selectedQuestionID ?? questions.first?.id
        return questions.first { $0.id == selected } ?? questions.first
    }

    func prepareComposer(for item: TTSItem) {
        questionComposer.prepare(questions: displayQuestions(for: item).map {
            QuestionChoiceConfiguration(id: $0.id, type: $0.type)
        })
    }

    func suggestionID(_ suggestion: TTSSuggestion, index: Int) -> String {
        suggestion.id?.nonemptyValue ?? "suggestion-\(index)"
    }

    func openSuggestionEditor(
        _ suggestion: TTSSuggestion,
        id: String,
        questionID: String
    ) {
        let draft = questionComposer.draft(for: questionID)
        let suggestionDraft = draft.suggestion(id)
        presentAnswerEditor(AnswerEditorContext(
            questionID: questionID,
            kind: .suggestion(id),
            existingTitle: suggestionDraft?.title ?? suggestion.title,
            existingDescription: suggestionDraft?.description ?? suggestion.description ?? "",
            existingAttachments: suggestionDraft?.attachmentURLs ?? []
        ))
    }

    func openAnswerEditor(for question: TTSQuestion) {
        let draft = questionComposer.draft(for: question.id)
        presentAnswerEditor(AnswerEditorContext(
            questionID: question.id,
            kind: .freeform,
            existingTitle: nil,
            existingDescription: draft.freeformText,
            existingAttachments: draft.attachmentURLs
        ))
    }

    func presentAnswerEditor(_ context: AnswerEditorContext) {
        answerEditorPresenter.present(context: context) { title, description, attachments in
            switch context.kind {
            case .freeform:
                questionComposer.updateDraft(description, for: context.questionID)
                questionComposer.setAttachments(attachments, for: context.questionID)
            case let .suggestion(suggestionID):
                guard let title else { return }
                questionComposer.applySuggestionEdit(
                    title: title,
                    description: description.nonemptyValue,
                    suggestionID: suggestionID,
                    attachments: attachments,
                    for: context.questionID
                )
            }
        }
    }

    func choiceSymbol(for type: TTSQuestionType, selected: Bool) -> String {
        switch (type, selected) {
        case (.singleChoice, true): "largecircle.fill.circle"
        case (.singleChoice, false): "circle"
        case (.multipleChoice, true): "checkmark.square.fill"
        case (.multipleChoice, false): "square"
        }
    }

    func openSupportingAttachment(_ attachment: TTSAttachment, item: TTSItem) {
        if attachment.kind == .narratedText || attachment.kind == .audio, attachment.isPlayable {
            controller.playAttachment(attachment, from: item)
        } else {
            controller.openAttachment(attachment)
        }
    }

    func canSubmit(item: TTSItem, questions: [TTSQuestion]) -> Bool {
        if item.questions?.isEmpty == false { return true }
        return questionComposer.submissions(questionIDs: questions.map(\.id)).first?.isSkipped == false
    }

    func submitAnswers(for item: TTSItem, questions: [TTSQuestion]) {
        answerEditorPresenter.cancel()
        let submissions = questionComposer.submissions(questionIDs: questions.map(\.id))
        if item.questions?.isEmpty == false {
            controller.submitBundle(
                item,
                drafts: submissions.map { submission in
                    TTSQuestionDraft(
                        questionID: submission.questionID,
                        answer: submission.answer ?? "",
                        suggestionID: submission.suggestionID,
                        attachmentURLs: submission.attachmentURLs.map(URL.init(fileURLWithPath:)),
                        interaction: interaction(for: submission),
                        suggestionIDs: submission.suggestionIDs,
                        selectedSuggestions: submission.selectedSuggestions
                    )
                }
            )
        } else if let submission = submissions.first, let answer = submission.answer {
            let suggestionIndex = item.suggestions?.enumerated().first {
                suggestionID($0.element, index: $0.offset) == submission.suggestionID
            }?.offset
            controller.answer(item, text: answer, suggestionIndex: suggestionIndex)
        }
    }

    func interaction(for submission: QuestionSubmission) -> String? {
        guard !submission.suggestionIDs.isEmpty else {
            return submission.answer == nil ? nil : "freeform"
        }
        let draft = questionComposer.draft(for: submission.questionID)
        let edited = submission.suggestionIDs.contains {
            draft.suggestion($0)?.isEdited == true
        }
        return edited ? "suggestion_edited" : "suggestion"
    }

    func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach files to your answer"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

}
