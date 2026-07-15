import Foundation

extension QueueStore {
    @discardableResult
    func answer(
        id: String,
        answer: String,
        suggestionIndex: Int? = nil,
        interaction: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> TTSItem {
        try withOperationsLock {
            var value = try requiredPendingQuestion(id: id)
            if let questions = value.questions, questions.count > 1 {
                throw QueueOperationError.bundleRequiresAtomicSubmission(id)
            }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw QueueOperationError.emptyAnswer }
            let nestedSuggestions = value.questions?.first?.suggestions
            let availableSuggestions = nestedSuggestions ?? value.suggestions
            if let suggestionIndex {
                guard let suggestions = availableSuggestions,
                      suggestions.indices.contains(suggestionIndex) else {
                    throw QueueOperationError.invalidSuggestionIndex(suggestionIndex)
                }
            }
            let selectedSuggestion = suggestionIndex.flatMap { availableSuggestions?[$0] }
            let response = TTSResponse(
                answer: trimmed,
                suggestionIndex: suggestionIndex,
                modified: selectedSuggestion.map { $0.title != trimmed } ?? false,
                answeredAt: now,
                interaction: interaction ?? (suggestionIndex == nil ? "freeform" : "suggestion"),
                suggestionID: selectedSuggestion?.id,
                suggestionIDs: selectedSuggestion?.id.map { [$0] },
                selectedSuggestions: selectedSuggestion.flatMap { suggestion in
                    suggestion.id.map {
                        [TTSSelectedSuggestion(
                            id: $0,
                            title: suggestion.title,
                            description: Self.nonempty(suggestion.description),
                            modified: false
                        )]
                    }
                }
            )
            value.response = response
            value.questionStatus = .answered
            if value.questions?.count == 1 {
                value.questions?[0].status = .answered
                value.questions?[0].response = response
            }
            try saveUnlocked(value)
            return value
        }
    }

    @discardableResult
    func skipQuestion(
        id: String,
        actor: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> TTSItem {
        try withOperationsLock {
            var value = try requiredPendingQuestion(id: id)
            if let questions = value.questions, questions.count > 1 {
                throw QueueOperationError.bundleRequiresAtomicSubmission(id)
            }
            value.questionStatus = .skipped
            if value.questions?.count == 1 {
                value.questions?[0].status = .skipped
                value.questions?[0].response = nil
            }
            try saveUnlocked(value)
            try saveOperation(QueueOperation(
                kind: .skip,
                sourceIDs: [id],
                replacementIDs: [],
                reason: nil,
                actor: actor,
                createdAt: now
            ))
            return value
        }
    }

    @discardableResult
    func submitBundle(
        id: String,
        drafts: [TTSQuestionDraft],
        actor: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> TTSItem {
        try withOperationsLock {
            var value = try requiredPendingQuestion(id: id)
            guard let questions = value.questions, !questions.isEmpty else {
                throw QueueOperationError.invalidBundleQuestions("questions must not be empty")
            }
            let questionIDs = questions.map(\.id)
            guard Set(questionIDs).count == questionIDs.count else {
                throw QueueOperationError.invalidBundleQuestions("question IDs must be unique")
            }
            let draftIDs = drafts.map(\.questionID)
            guard Set(draftIDs).count == draftIDs.count else {
                throw QueueOperationError.invalidBundleDrafts("question IDs must not be repeated")
            }
            guard Set(draftIDs) == Set(questionIDs), drafts.count == questions.count else {
                throw QueueOperationError.invalidBundleDrafts("provide exactly one draft for every question")
            }
            guard questions.allSatisfy({ $0.status == .pending }) else {
                throw QueueOperationError.questionAlreadyResolved(id)
            }

            let draftsByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.questionID, $0) })
            for question in questions {
                let draft = draftsByID[question.id]!
                let selectedIDs = Self.selectedSuggestionIDs(for: draft)
                guard Set(selectedIDs).count == selectedIDs.count else {
                    throw QueueOperationError.invalidBundleDrafts(
                        "selected suggestion IDs must be unique for question \(question.id)"
                    )
                }
                if question.type == .singleChoice, selectedIDs.count > 1 {
                    throw QueueOperationError.invalidBundleDrafts(
                        "question \(question.id) accepts only one suggestion"
                    )
                }
                for suggestionID in selectedIDs {
                    guard question.suggestions?.contains(where: { $0.id == suggestionID }) == true else {
                        throw QueueOperationError.invalidSuggestionID(suggestionID)
                    }
                }
                let submittedSuggestionIDs = draft.selectedSuggestions.map(\.id)
                guard Set(submittedSuggestionIDs).count == submittedSuggestionIDs.count else {
                    throw QueueOperationError.invalidBundleDrafts(
                        "selected suggestion details must not repeat IDs for question \(question.id)"
                    )
                }
                if !submittedSuggestionIDs.isEmpty,
                   submittedSuggestionIDs != selectedIDs
                {
                    throw QueueOperationError.invalidBundleDrafts(
                        "selected suggestion details must match selected ID order for question \(question.id)"
                    )
                }
                if draft.selectedSuggestions.contains(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    throw QueueOperationError.invalidBundleDrafts(
                        "selected suggestion titles must not be blank for question \(question.id)"
                    )
                }
                for url in draft.attachmentURLs {
                    guard url.isFileURL, Self.isReadableRegularFile(url) else {
                        throw QueueOperationError.invalidAnswerAttachment(url.path)
                    }
                }
            }

            var copiedURLs: [URL] = []
            var itemWasSaved = false
            defer {
                if !itemWasSaved {
                    for url in copiedURLs { try? FileManager.default.removeItem(at: url) }
                }
            }

            var updatedQuestions: [TTSQuestion] = []
            for var question in questions {
                let draft = draftsByID[question.id]!
                let trimmed = draft.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                let selectedIDs = Self.selectedSuggestionIDs(for: draft)
                let answerAttachments = try copyAnswerAttachments(
                    draft.attachmentURLs,
                    item: value,
                    questionID: question.id,
                    copiedURLs: &copiedURLs
                )
                guard !trimmed.isEmpty || !answerAttachments.isEmpty else {
                    question.status = .skipped
                    question.response = nil
                    updatedQuestions.append(question)
                    continue
                }

                let submittedByID = Dictionary(
                    uniqueKeysWithValues: draft.selectedSuggestions.map { ($0.id, $0) }
                )
                let selectedSuggestions = selectedIDs.compactMap { suggestionID -> TTSSelectedSuggestion? in
                    guard let original = question.suggestions?.first(where: { $0.id == suggestionID }) else {
                        return nil
                    }
                    let submitted = submittedByID[suggestionID]
                    let title = submitted?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? original.title
                    let description = submitted.map {
                        Self.nonempty($0.description)
                    } ?? Self.nonempty(original.description)
                    return TTSSelectedSuggestion(
                        id: suggestionID,
                        title: title,
                        description: description,
                        modified: title != original.title
                            || description != Self.nonempty(original.description)
                    )
                }
                let canonicalSuggestionAnswer = selectedSuggestions
                    .map(\.title)
                    .joined(separator: ", ")
                let legacySuggestionID = question.type == .singleChoice ? selectedIDs.first : nil
                let legacySuggestionIndex = legacySuggestionID.flatMap { suggestionID in
                    question.suggestions?.firstIndex { $0.id == suggestionID }
                }
                let wasModified = !selectedIDs.isEmpty
                    && (canonicalSuggestionAnswer != trimmed
                        || selectedSuggestions.contains(where: \.modified))
                question.status = .answered
                question.response = TTSResponse(
                    answer: trimmed,
                    suggestionIndex: legacySuggestionIndex,
                    modified: wasModified,
                    answeredAt: now,
                    interaction: draft.interaction
                        ?? (selectedIDs.isEmpty
                            ? (answerAttachments.isEmpty ? "freeform" : "attachments")
                            : "suggestion"),
                    suggestionID: legacySuggestionID,
                    suggestionIDs: selectedIDs.isEmpty ? nil : selectedIDs,
                    selectedSuggestions: selectedSuggestions.isEmpty ? nil : selectedSuggestions,
                    attachments: answerAttachments.isEmpty ? nil : answerAttachments
                )
                updatedQuestions.append(question)
            }

            value.questions = updatedQuestions
            value.questionStatus = .answered
            value.response = nil
            try saveUnlocked(value)
            itemWasSaved = true
            try saveOperation(QueueOperation(
                kind: .answer,
                sourceIDs: [id],
                replacementIDs: [],
                reason: nil,
                actor: actor,
                createdAt: now
            ))
            return value
        }
    }

}
