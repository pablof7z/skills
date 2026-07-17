import Foundation

struct QuestionSubmission: Equatable {
    let questionID: String
    let answer: String?
    let suggestionIDs: [String]
    let selectedSuggestions: [TTSQuestionDraftSuggestion]
    let attachmentURLs: [String]

    var suggestionID: String? { suggestionIDs.count == 1 ? suggestionIDs.first : nil }
    var isSkipped: Bool { answer == nil && attachmentURLs.isEmpty }
}

struct QuestionChoiceConfiguration: Equatable {
    let id: String
    let type: TTSQuestionType

    init(id: String, type: TTSQuestionType = .singleChoice) {
        self.id = id
        self.type = type
    }
}

struct SuggestionDraftState: Equatable {
    var title: String
    var description: String?
    var isEdited = false
    var attachmentURLs: [URL] = []

    var answer: String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct QuestionDraftState: Equatable {
    var freeformText = ""
    var selectedSuggestionIDs: [String] = []
    var suggestions: [String: SuggestionDraftState] = [:]
    var attachmentURLs: [URL] = []

    var selectedSuggestionID: String? { selectedSuggestionIDs.first }

    func suggestion(_ id: String) -> SuggestionDraftState? { suggestions[id] }
}

struct QuestionComposerModel: Equatable {
    private(set) var selectedQuestionID: String?
    private(set) var drafts: [String: QuestionDraftState] = [:]
    private(set) var questionTypes: [String: TTSQuestionType] = [:]
    private(set) var reviewedQuestionIDs: Set<String> = []

    mutating func prepare(questionIDs: [String]) {
        prepare(questions: questionIDs.map { QuestionChoiceConfiguration(id: $0) })
    }

    mutating func prepare(questions: [QuestionChoiceConfiguration]) {
        let available = Set(questions.map(\.id))
        drafts = drafts.filter { available.contains($0.key) }
        reviewedQuestionIDs.formIntersection(available)
        questionTypes = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.type) })
        for question in questions where drafts[question.id] == nil {
            drafts[question.id] = QuestionDraftState()
        }
        if selectedQuestionID.map({ available.contains($0) }) != true {
            selectedQuestionID = questions.first?.id
        }
    }

    func draft(for questionID: String) -> QuestionDraftState {
        drafts[questionID] ?? QuestionDraftState()
    }

    func status(for questionID: String) -> TTSQuestionStatus {
        if !submission(for: questionID).isSkipped { return .answered }
        return reviewedQuestionIDs.contains(questionID) ? .skipped : .pending
    }

    func isComplete(questionIDs: [String]) -> Bool {
        questionIDs.allSatisfy { status(for: $0) != .pending }
    }

    mutating func navigate(to questionID: String) {
        guard questionID != selectedQuestionID else { return }
        markSelectedQuestionReviewed()
        selectQuestion(questionID)
    }

    mutating func advance(questionIDs: [String]) {
        markSelectedQuestionReviewed()
        guard !questionIDs.isEmpty else { return }
        let selectedIndex = selectedQuestionID.flatMap { questionIDs.firstIndex(of: $0) } ?? -1
        let orderedIDs = Array(questionIDs.dropFirst(selectedIndex + 1))
            + Array(questionIDs.prefix(selectedIndex + 1))
        if let next = orderedIDs.first(where: { status(for: $0) == .pending }) {
            selectQuestion(next)
        }
    }

    mutating func selectQuestion(_ questionID: String) {
        selectedQuestionID = questionID
        ensureDraft(for: questionID)
    }

    mutating func updateDraft(_ value: String, for questionID: String) {
        ensureDraft(for: questionID)
        drafts[questionID]?.freeformText = value
        guard questionType(for: questionID) == .singleChoice,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts[questionID]?.selectedSuggestionIDs = []
    }

    mutating func selectSuggestion(
        id: String,
        title: String,
        description: String? = nil,
        for questionID: String
    ) {
        ensureDraft(for: questionID)
        if drafts[questionID]?.suggestions[id] == nil {
            drafts[questionID]?.suggestions[id] = SuggestionDraftState(title: title, description: description)
        } else if drafts[questionID]?.suggestions[id]?.isEdited != true {
            drafts[questionID]?.suggestions[id]?.title = title
            drafts[questionID]?.suggestions[id]?.description = description
        }
        if questionType(for: questionID) == .multipleChoice {
            if let index = drafts[questionID]?.selectedSuggestionIDs.firstIndex(of: id) {
                drafts[questionID]?.selectedSuggestionIDs.remove(at: index)
            } else {
                drafts[questionID]?.selectedSuggestionIDs.append(id)
            }
        } else {
            drafts[questionID]?.selectedSuggestionIDs = [id]
        }
    }

    mutating func applySuggestionEdit(
        title: String,
        description: String?,
        suggestionID: String,
        attachments: [URL],
        for questionID: String
    ) {
        ensureDraft(for: questionID)
        drafts[questionID]?.suggestions[suggestionID] = SuggestionDraftState(
            title: title,
            description: description,
            isEdited: true,
            attachmentURLs: Self.deduplicated(attachments)
        )
        if questionType(for: questionID) == .multipleChoice {
            if drafts[questionID]?.selectedSuggestionIDs.contains(suggestionID) != true {
                drafts[questionID]?.selectedSuggestionIDs.append(suggestionID)
            }
        } else {
            drafts[questionID]?.selectedSuggestionIDs = [suggestionID]
        }
    }

    mutating func addAttachments(_ urls: [URL], for questionID: String) {
        ensureDraft(for: questionID)
        let current = drafts[questionID]?.attachmentURLs ?? []
        drafts[questionID]?.attachmentURLs = Self.deduplicated(current + urls)
    }

    mutating func setAttachments(_ urls: [URL], for questionID: String) {
        ensureDraft(for: questionID)
        drafts[questionID]?.attachmentURLs = Self.deduplicated(urls)
    }

    mutating func removeAttachment(_ url: URL, for questionID: String) {
        ensureDraft(for: questionID)
        let path = url.standardizedFileURL.path
        drafts[questionID]?.attachmentURLs.removeAll { $0.standardizedFileURL.path == path }
    }

    mutating func removeEditedSuggestionAttachment(
        _ url: URL,
        suggestionID: String,
        for questionID: String
    ) {
        ensureDraft(for: questionID)
        let path = url.standardizedFileURL.path
        drafts[questionID]?.suggestions[suggestionID]?.attachmentURLs.removeAll {
            $0.standardizedFileURL.path == path
        }
    }

    func submissions(questionIDs: [String]) -> [QuestionSubmission] {
        questionIDs.map(submission(for:))
    }

    mutating func reset() {
        selectedQuestionID = nil
        drafts = [:]
        questionTypes = [:]
        reviewedQuestionIDs = []
    }

    private func submission(for questionID: String) -> QuestionSubmission {
        let value = draft(for: questionID)
        let selectedAnswers = value.selectedSuggestionIDs.compactMap { value.suggestions[$0]?.answer }
        let selection = selectedAnswers.joined(separator: ", ")
        let note = value.freeformText.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String?
        if questionType(for: questionID) == .multipleChoice, !selection.isEmpty, !note.isEmpty {
            answer = "\(selection)\n\nAdditional note: \(note)"
        } else {
            let combined = selection.isEmpty ? note : selection
            answer = combined.isEmpty ? nil : combined
        }
        let selectedAttachments = value.selectedSuggestionIDs.flatMap {
            value.suggestions[$0]?.attachmentURLs ?? []
        }
        let selectedSuggestions = value.selectedSuggestionIDs.compactMap { suggestionID in
            value.suggestions[suggestionID].map {
                TTSQuestionDraftSuggestion(id: suggestionID, title: $0.title, description: $0.description)
            }
        }
        return QuestionSubmission(
            questionID: questionID,
            answer: answer,
            suggestionIDs: value.selectedSuggestionIDs,
            selectedSuggestions: selectedSuggestions,
            attachmentURLs: Self.deduplicated(value.attachmentURLs + selectedAttachments)
                .map(\.standardizedFileURL.path)
        )
    }

    private mutating func markSelectedQuestionReviewed() {
        if let selectedQuestionID { reviewedQuestionIDs.insert(selectedQuestionID) }
    }

    private mutating func ensureDraft(for questionID: String) {
        if drafts[questionID] == nil { drafts[questionID] = QuestionDraftState() }
    }

    private func questionType(for questionID: String) -> TTSQuestionType {
        questionTypes[questionID] ?? .singleChoice
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}
