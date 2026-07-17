import AppKit

extension NowSpeakingHUDView {
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

    func openSuggestionEditor(_ suggestion: TTSSuggestion, id: String, questionID: String) {
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

    func canSubmit(item _: TTSItem, questions: [TTSQuestion]) -> Bool {
        questionComposer.isComplete(questionIDs: questions.map(\.id))
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
        } else if let submission = submissions.first {
            if let answer = submission.answer {
                let suggestionIndex = item.suggestions?.enumerated().first {
                    suggestionID($0.element, index: $0.offset) == submission.suggestionID
                }?.offset
                controller.answer(item, text: answer, suggestionIndex: suggestionIndex)
            } else {
                controller.skipQuestion(item)
            }
        }
    }

    func questionStatusSymbol(_ status: TTSQuestionStatus) -> String? {
        switch status {
        case .answered: "checkmark.circle.fill"
        case .skipped: "forward.end.circle.fill"
        case .pending, .superseded: nil
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
