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

    func itemsChangeToken() throws -> Date {
        try prepare()
        let attributes = try FileManager.default.attributesOfItem(atPath: itemsDirectory.path)
        return attributes[.modificationDate] as? Date ?? .distantPast
    }

    func loadItemsUnlocked() throws -> [TTSItem] {
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

    func saveUnlocked(_ item: TTSItem, mergingConcurrentState: Bool = false) throws {
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
        value.questionsPreamble = value.questionsPreamble ?? persisted.questionsPreamble
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

    func itemUnlocked(id: String) throws -> TTSItem? {
        try prepare()
        let url = itemsDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TTSItem.self, from: Data(contentsOf: url))
    }

}
