import AppKit
import Combine
import SwiftUI

@MainActor
final class NowSpeakingPresentation: ObservableObject {
    @Published private(set) var isHovered = false
    @Published var lingeringItem: TTSItem?
    @Published var lingeringTime: TimeInterval = 0
    @Published var lingeringDuration: TimeInterval = 0
    @Published var selectedAttachmentID: String?
    @Published private(set) var selectedAttachmentText: String?
    @Published private(set) var selectedAttachmentImage: NSImage?
    @Published var historyEntityFilters = HistoryEntityFilters()
    @Published var historySearchQuery = ""
    @Published var historyAgeFilter: HistoryAgeFilter = .default
    @Published private(set) var hasInteractedWithHistory = false
    @Published var isHistorySearchVisible = false
    @Published var isViewingArchive = false
    @Published private(set) var pendingPreviewItem: TTSItem?
    @Published private(set) var hiddenItemID: String?
    private var hoverExitTask: Task<Void, Never>?

    func updateHover(_ hovering: Bool) {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        if hovering {
            isHovered = true
            return
        }

        hoverExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            hoverExitTask = nil
            isHovered = false
        }
    }

    func clearHover() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        isHovered = false
    }

    func selectAttachment(
        _ attachmentID: String?,
        text: String? = nil,
        image: NSImage? = nil
    ) {
        selectedAttachmentID = attachmentID
        selectedAttachmentText = attachmentID == nil ? nil : text
        selectedAttachmentImage = attachmentID == nil ? nil : image
    }

    func previewPendingItem(_ item: TTSItem) {
        hiddenItemID = nil
        pendingPreviewItem = item
        selectAttachment(nil)
    }

    func revealForDirectSelection(itemID _: String) {
        hiddenItemID = nil
        pendingPreviewItem = nil
        selectAttachment(nil)
    }

    func revealAutomatically(itemID: String) {
        hiddenItemID = PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: itemID,
            currentlyHidden: hiddenItemID
        )
    }

    func showHistory(hiding itemID: String?) {
        hiddenItemID = itemID
        selectAttachment(nil)
    }

    func registerHistoryInteraction() {
        hasInteractedWithHistory = true
    }

    func toggleHistoryProject(_ project: String) {
        registerHistoryInteraction()
        historyEntityFilters.toggle(project: project)
    }

    func toggleHistoryAgent(_ agent: HistoryAgentFilter) {
        registerHistoryInteraction()
        historyEntityFilters.toggle(agent: agent)
    }

    func retainAvailableHistoryFilters(
        projects: Set<String>,
        agents: Set<HistoryAgentFilter>
    ) {
        var retained = historyEntityFilters
        retained.projects.formIntersection(projects)
        retained.agents.formIntersection(agents)
        if retained != historyEntityFilters { historyEntityFilters = retained }
    }

    func showHistorySearch() {
        isHistorySearchVisible = true
        registerHistoryInteraction()
    }

    func hideHistorySearch() {
        historySearchQuery = ""
        isHistorySearchVisible = false
    }

    func updatePendingPreview(with item: TTSItem?) {
        guard let preview = pendingPreviewItem else { return }
        guard let item, item.id == preview.id else {
            pendingPreviewItem = nil
            return
        }
        pendingPreviewItem = item
    }

    func clearPendingPreview() {
        pendingPreviewItem = nil
    }
}

enum PendingQuestionRetention {
    static func retainedItem(
        currentItem: TTSItem?,
        lingeringItem: TTSItem?,
        lastCurrentItem: TTSItem?
    ) -> TTSItem? {
        [currentItem, lingeringItem, lastCurrentItem]
            .compactMap { $0 }
            .first(where: \.isPendingQuestion)
    }

    static func shouldRetain(lastCurrentItem: TTSItem?, lingeringItem: TTSItem?) -> Bool {
        retainedItem(
            currentItem: nil,
            lingeringItem: lingeringItem,
            lastCurrentItem: lastCurrentItem
        ) != nil
    }
}

enum PlayerNavigationPolicy {
    static func shouldDisplay(itemID: String?, hiddenItemID: String?) -> Bool {
        itemID != nil && itemID != hiddenItemID
    }

    static func shouldShowMiniPlayer(currentItemID: String?, hiddenItemID: String?) -> Bool {
        guard let currentItemID else { return false }
        return currentItemID == hiddenItemID
    }

    static func hiddenItemID(
        afterAutomaticallySelecting itemID: String,
        currentlyHidden hiddenItemID: String?
    ) -> String? {
        hiddenItemID == itemID ? hiddenItemID : nil
    }
}

enum PlayerHistoryToolbarPolicy {
    static let toolbarIdentifier = NSToolbar.Identifier("TTSHistoryToolbar")
    static let backItemIdentifier = NSToolbarItem.Identifier("TTSHistoryBack")
    static let filterItemIdentifier = NSToolbarItem.Identifier("TTSHistoryProjectFilter")
    static let searchButtonItemIdentifier = NSToolbarItem.Identifier("TTSHistorySearchButton")
    static let searchFieldItemIdentifier = NSToolbarItem.Identifier("TTSHistorySearchField")

    static let rootItemIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        searchButtonItemIdentifier,
        filterItemIdentifier,
    ]

    static let allowedItemIdentifiers: [NSToolbarItem.Identifier] = [
        backItemIdentifier,
        .flexibleSpace,
        searchButtonItemIdentifier,
        searchFieldItemIdentifier,
        filterItemIdentifier,
    ]
}

enum PlayerHoverContinuation {
    static func shouldRetainCurrentContent(
        isHovered: Bool,
        isGracePeriodActive: Bool,
        hasCurrentContent: Bool
    ) -> Bool {
        hasCurrentContent && (isHovered || isGracePeriodActive)
    }
}

enum QuestionAudioReview {
    static func canReplay(
        _ item: TTSItem,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> Bool {
        item.isQuestion
            && item.status != .generating
            && fileExists(item.outputFile)
    }
}

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

    mutating func prepare(questionIDs: [String]) {
        prepare(questions: questionIDs.map { QuestionChoiceConfiguration(id: $0) })
    }

    mutating func prepare(questions: [QuestionChoiceConfiguration]) {
        let available = Set(questions.map(\.id))
        drafts = drafts.filter { available.contains($0.key) }
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

    mutating func selectQuestion(_ questionID: String) {
        selectedQuestionID = questionID
        if drafts[questionID] == nil {
            drafts[questionID] = QuestionDraftState()
        }
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
            drafts[questionID]?.suggestions[id] = SuggestionDraftState(
                title: title,
                description: description
            )
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
        questionIDs.map { questionID in
            let value = draft(for: questionID)
            let selectedAnswers = value.selectedSuggestionIDs.compactMap {
                value.suggestions[$0]?.answer
            }
            let selection = selectedAnswers.joined(separator: ", ")
            let note = value.freeformText.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer: String?
            if questionType(for: questionID) == .multipleChoice,
               !selection.isEmpty,
               !note.isEmpty
            {
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
                    TTSQuestionDraftSuggestion(
                        id: suggestionID,
                        title: $0.title,
                        description: $0.description
                    )
                }
            }
            return QuestionSubmission(
                questionID: questionID,
                answer: answer,
                suggestionIDs: value.selectedSuggestionIDs,
                selectedSuggestions: selectedSuggestions,
                attachmentURLs: Self.deduplicated(
                    value.attachmentURLs + selectedAttachments
                ).map(\.standardizedFileURL.path)
            )
        }
    }

    mutating func reset() {
        selectedQuestionID = nil
        drafts = [:]
        questionTypes = [:]
    }

    private mutating func ensureDraft(for questionID: String) {
        if drafts[questionID] == nil {
            drafts[questionID] = QuestionDraftState()
        }
    }

    private func questionType(for questionID: String) -> TTSQuestionType {
        questionTypes[questionID] ?? .singleChoice
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}
