import Darwin
import Foundation

enum QueueOperationKind: String, Codable, Equatable {
    case answer
    case skip
    case archive
    case restore
    case supersede
}

struct QueueOperation: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var kind: QueueOperationKind
    var sourceIDs: [String]
    var replacementIDs: [String]
    var reason: String?
    var actor: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sourceIDs = "source_ids"
        case replacementIDs = "replacement_ids"
        case reason
        case actor
        case createdAt = "created_at"
    }
}

enum QueueOperationError: Error, LocalizedError, Equatable {
    case itemNotFound(String)
    case questionAlreadyResolved(String)
    case emptyAnswer
    case invalidSuggestionIndex(Int)
    case noSources
    case noReplacements
    case emptyReason
    case supersessionCycle
    case bundleRequiresAtomicSubmission(String)
    case invalidBundleQuestions(String)
    case invalidBundleDrafts(String)
    case invalidSuggestionID(String)
    case invalidAnswerAttachment(String)

    var errorDescription: String? {
        switch self {
        case let .itemNotFound(id): "TTS item not found: \(id)"
        case let .questionAlreadyResolved(id): "Question is no longer pending: \(id)"
        case .emptyAnswer: "An answer cannot be empty."
        case let .invalidSuggestionIndex(index): "Suggestion index is out of range: \(index)"
        case .noSources: "At least one source item is required."
        case .noReplacements: "At least one replacement item is required."
        case .emptyReason: "A supersession reason is required."
        case .supersessionCycle: "Supersession would create a cycle."
        case let .bundleRequiresAtomicSubmission(id): "Question bundle requires one atomic submission: \(id)"
        case let .invalidBundleQuestions(message): "Invalid question bundle: \(message)"
        case let .invalidBundleDrafts(message): "Invalid question drafts: \(message)"
        case let .invalidSuggestionID(id): "Suggestion ID was not found: \(id)"
        case let .invalidAnswerAttachment(path): "Answer attachment is not a readable file: \(path)"
        }
    }
}

struct QueueStore {
    let stateDirectory: URL

    init(stateDirectory: URL = QueueStore.defaultStateDirectory()) {
        self.stateDirectory = stateDirectory
    }

    var itemsDirectory: URL {
        stateDirectory.appendingPathComponent("items", isDirectory: true)
    }

    var processFile: URL {
        stateDirectory.appendingPathComponent("menu.pid")
    }

    var lockFile: URL {
        stateDirectory.appendingPathComponent("menu.flock")
    }

    var globalPlaybackPauseFile: URL {
        stateDirectory.appendingPathComponent("playback-paused")
    }

    var operationsDirectory: URL {
        stateDirectory.appendingPathComponent("operations", isDirectory: true)
    }

    var operationsLockFile: URL {
        stateDirectory.appendingPathComponent("operations.flock")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: operationsDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadItems() throws -> [TTSItem] {
        try withOperationsReadLock {
            try loadItemsUnlocked()
        }
    }

    private func loadItemsUnlocked() throws -> [TTSItem] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TTSItem.self, from: data)
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id < $1.id
                }
                return $0.createdAt < $1.createdAt
            }
    }

    func save(_ item: TTSItem) throws {
        try withOperationsLock {
            try saveUnlocked(item, mergingConcurrentState: true)
        }
    }

    private func saveUnlocked(_ item: TTSItem, mergingConcurrentState: Bool = false) throws {
        try prepare()
        let destination = itemsDirectory.appendingPathComponent("\(item.id).json")
        var value = item
        if let data = try? Data(contentsOf: destination),
           let existing = try? JSONDecoder().decode(TTSItem.self, from: data) {
            value.attachments = Self.mergingPreparedAttachments(
                value.attachments,
                with: existing.attachments
            )
            if mergingConcurrentState {
                value = Self.mergingCoordinationState(value, with: existing)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: destination, options: .atomic)
    }

    static func mergingCoordinationState(_ proposed: TTSItem, with persisted: TTSItem) -> TTSItem {
        var value = proposed
        value.kind = value.kind ?? persisted.kind
        value.suggestions = value.suggestions ?? persisted.suggestions
        value.bundleTitle = value.bundleTitle ?? persisted.bundleTitle
        value.bundleDescription = value.bundleDescription ?? persisted.bundleDescription
        value.primaryMessage = value.primaryMessage ?? persisted.primaryMessage
        if persisted.questionStatus?.isTerminal == true,
           value.questionStatus?.isTerminal != true {
            value.questionStatus = persisted.questionStatus
            value.response = persisted.response
            value.supersededBy = persisted.supersededBy
            value.questions = persisted.questions
        } else {
            value.questionStatus = value.questionStatus ?? persisted.questionStatus
            value.response = value.response ?? persisted.response
            value.supersededBy = value.supersededBy ?? persisted.supersededBy
            value.questions = value.questions ?? persisted.questions
        }
        // Generic playback/generation saves are never archive operations. A
        // stale copy commonly carries the legacy explicit `false`; preserve a
        // concurrent archive until setArchived(_:id:) performs a restore.
        if persisted.archived, !value.archived {
            value.isArchived = true
            value.archivedAt = value.archivedAt ?? persisted.archivedAt
            value.archiveReason = value.archiveReason ?? persisted.archiveReason
            value.archivedBy = value.archivedBy ?? persisted.archivedBy
        }
        value.playbackInitiator = value.playbackInitiator ?? persisted.playbackInitiator
        value.engagement = value.engagement ?? persisted.engagement
        value.userActivity = value.userActivity ?? persisted.userActivity
        return value
    }

    func item(id: String) throws -> TTSItem? {
        try withOperationsReadLock {
            try itemUnlocked(id: id)
        }
    }

    private func itemUnlocked(id: String) throws -> TTSItem? {
        try prepare()
        let url = itemsDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TTSItem.self, from: Data(contentsOf: url))
    }

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

    @discardableResult
    func setArchived(
        _ archived: Bool,
        id: String,
        reason: String? = nil,
        actor: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> TTSItem {
        try withOperationsLock {
            guard var value = try itemUnlocked(id: id) else { throw QueueOperationError.itemNotFound(id) }
            value.isArchived = archived
            value.archivedAt = archived ? now : nil
            value.archiveReason = archived ? reason : nil
            value.archivedBy = archived ? actor : nil
            try saveUnlocked(value)
            try saveOperation(QueueOperation(
                kind: archived ? .archive : .restore,
                sourceIDs: [id],
                replacementIDs: [],
                reason: reason,
                actor: actor,
                createdAt: now
            ))
            return value
        }
    }

    @discardableResult
    func supersede(
        sourceIDs: [String],
        with replacementIDs: [String],
        reason: String,
        actor: String? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> [TTSItem] {
        try withOperationsLock {
            let sources = Array(Set(sourceIDs)).sorted()
            let replacements = Array(Set(replacementIDs)).sorted()
            guard !sources.isEmpty else { throw QueueOperationError.noSources }
            guard !replacements.isEmpty else { throw QueueOperationError.noReplacements }
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty else { throw QueueOperationError.emptyReason }

            let allItems = try loadItemsUnlocked()
            let byID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
            for replacement in replacements where byID[replacement] == nil {
                throw QueueOperationError.itemNotFound(replacement)
            }
            for source in sources {
                guard let item = byID[source] else { throw QueueOperationError.itemNotFound(source) }
                guard item.isPendingQuestion else { throw QueueOperationError.questionAlreadyResolved(source) }
            }
            guard Set(sources).isDisjoint(with: replacements) else {
                throw QueueOperationError.supersessionCycle
            }

            var graph = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0.supersededBy ?? []) })
            for source in sources { graph[source] = replacements }
            for source in sources {
                for replacement in replacements where Self.reaches(source, from: replacement, graph: graph) {
                    throw QueueOperationError.supersessionCycle
                }
            }

            var updated: [TTSItem] = []
            for source in sources {
                var item = byID[source]!
                item.questionStatus = .superseded
                item.supersededBy = replacements
                item.isArchived = true
                item.archivedAt = now
                item.archiveReason = trimmedReason
                item.archivedBy = actor
                try saveUnlocked(item)
                updated.append(item)
            }
            try saveOperation(QueueOperation(
                kind: .supersede,
                sourceIDs: sources,
                replacementIDs: replacements,
                reason: trimmedReason,
                actor: actor,
                createdAt: now
            ))
            return updated
        }
    }

    private func requiredPendingQuestion(id: String) throws -> TTSItem {
        guard let value = try itemUnlocked(id: id) else { throw QueueOperationError.itemNotFound(id) }
        guard value.isPendingQuestion else { throw QueueOperationError.questionAlreadyResolved(id) }
        return value
    }

    private static func selectedSuggestionIDs(for draft: TTSQuestionDraft) -> [String] {
        if !draft.suggestionIDs.isEmpty { return draft.suggestionIDs }
        return draft.suggestionID.map { [$0] } ?? []
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func copyAnswerAttachments(
        _ sourceURLs: [URL],
        item: TTSItem,
        questionID: String,
        copiedURLs: inout [URL]
    ) throws -> [TTSAnswerAttachment] {
        guard !sourceURLs.isEmpty else { return [] }
        let itemAssets = item.assetDirectory.flatMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
        } ?? stateDirectory
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(item.id), isDirectory: true)
        let destinationDirectory = itemAssets
            .appendingPathComponent("answer-attachments", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(questionID), isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        return try sourceURLs.map { originalURL in
            let accessed = originalURL.startAccessingSecurityScopedResource()
            defer { if accessed { originalURL.stopAccessingSecurityScopedResource() } }
            let sourceURL = originalURL.resolvingSymlinksInPath()
            guard Self.isReadableRegularFile(sourceURL) else {
                throw QueueOperationError.invalidAnswerAttachment(originalURL.path)
            }
            let label = originalURL.lastPathComponent.isEmpty ? "Attachment" : originalURL.lastPathComponent
            let destination = Self.availableDestination(
                named: label,
                in: destinationDirectory
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            copiedURLs.append(destination)
            return TTSAnswerAttachment(
                id: "\(Self.safePathComponent(questionID))-answer-\(UUID().uuidString.lowercased())",
                label: label,
                sourceFile: destination.path
            )
        }
    }

    private static func isReadableRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let string = String(result).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return string.isEmpty ? "item" : string
    }

    private static func availableDestination(named filename: String, in directory: URL) -> URL {
        let original = URL(fileURLWithPath: filename).lastPathComponent
        let fallback = original.isEmpty ? "attachment" : original
        let extensionName = URL(fileURLWithPath: fallback).pathExtension
        let stem = URL(fileURLWithPath: fallback).deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(fallback)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = extensionName.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(extensionName)"
            candidate = directory.appendingPathComponent(nextName)
            suffix += 1
        }
        return candidate
    }

    private func saveOperation(_ operation: QueueOperation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = operationsDirectory.appendingPathComponent("\(operation.createdAt)-\(operation.id).json")
        try encoder.encode(operation).write(to: url, options: .atomic)
    }

    private func withOperationsLock<T>(_ body: () throws -> T) throws -> T {
        try withFileLock(LOCK_EX, body)
    }

    private func withOperationsReadLock<T>(_ body: () throws -> T) throws -> T {
        try withFileLock(LOCK_SH, body)
    }

    private func withFileLock<T>(_ operation: Int32, _ body: () throws -> T) throws -> T {
        try prepare()
        let descriptor = open(operationsLockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open operations lock") }
        defer { close(descriptor) }
        guard flock(descriptor, operation) == 0 else { throw posixError("lock operations") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func reaches(
        _ target: String,
        from start: String,
        graph: [String: [String]]
    ) -> Bool {
        var pending = [start]
        var visited = Set<String>()
        while let next = pending.popLast() {
            if next == target { return true }
            guard visited.insert(next).inserted else { continue }
            pending.append(contentsOf: graph[next] ?? [])
        }
        return false
    }

    private func posixError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation): \(String(cString: strerror(code)))"]
        )
    }

    static func mergingPreparedAttachments(
        _ proposed: [TTSAttachment]?,
        with persisted: [TTSAttachment]?
    ) -> [TTSAttachment]? {
        guard let proposed else { return persisted }
        guard let persisted else { return proposed }
        let persistedByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        return proposed.map { attachment in
            guard attachment.status == .preparing,
                  let durable = persistedByID[attachment.id],
                  durable.status != .preparing else { return attachment }
            return durable
        }
    }

    func isGlobalPlaybackPaused() -> Bool {
        FileManager.default.fileExists(atPath: globalPlaybackPauseFile.path)
    }

    func setGlobalPlaybackPaused(_ paused: Bool) throws {
        try prepare()
        if paused {
            try Data("paused\n".utf8).write(to: globalPlaybackPauseFile, options: .atomic)
        } else if FileManager.default.fileExists(atPath: globalPlaybackPauseFile.path) {
            try FileManager.default.removeItem(at: globalPlaybackPauseFile)
        }
    }

    func recoverInterruptedItems() throws {
        for var item in try loadItems() where item.status == .playing || item.status == .paused {
            guard FileManager.default.fileExists(atPath: item.outputFile) else {
                item.status = .failed
                item.error = "Audio file is no longer available."
                item.completedAt = Int64(Date().timeIntervalSince1970)
                try save(item)
                continue
            }
            item.status = .queued
            item.startedAt = nil
            item.completedAt = nil
            item.error = nil
            try save(item)
        }
    }

    static func defaultStateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--state-dir"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let explicit = environment["TTS_STATE_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("tts", isDirectory: true)
        }
        let home = environment["HOME"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/state/tts", isDirectory: true)
    }
}

final class MenuInstanceLock {
    private let store: QueueStore
    private var fileDescriptor: Int32 = -1

    init(store: QueueStore) {
        self.store = store
    }

    deinit {
        release()
    }

    func acquire(processID: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> Bool {
        guard fileDescriptor == -1 else { return true }
        try store.prepare()

        let descriptor = open(store.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw posixError("open")
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return false
            }
            throw posixError("flock", code: lockError)
        }

        do {
            try Data("\(processID)\n".utf8).write(to: store.processFile, options: .atomic)
            fileDescriptor = descriptor
            return true
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        try? FileManager.default.removeItem(at: store.processFile)
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    private func posixError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation) TTS menu lock: \(String(cString: strerror(code)))"]
        )
    }
}
