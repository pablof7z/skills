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
        if persisted.questionStatus?.isTerminal == true,
           value.questionStatus?.isTerminal != true {
            value.questionStatus = persisted.questionStatus
            value.response = persisted.response
            value.supersededBy = persisted.supersededBy
        } else {
            value.questionStatus = value.questionStatus ?? persisted.questionStatus
            value.response = value.response ?? persisted.response
            value.supersededBy = value.supersededBy ?? persisted.supersededBy
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
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw QueueOperationError.emptyAnswer }
            if let suggestionIndex {
                guard let suggestions = value.suggestions,
                      suggestions.indices.contains(suggestionIndex) else {
                    throw QueueOperationError.invalidSuggestionIndex(suggestionIndex)
                }
            }
            let selectedTitle = suggestionIndex.flatMap { value.suggestions?[$0].title }
            value.response = TTSResponse(
                answer: trimmed,
                suggestionIndex: suggestionIndex,
                modified: selectedTitle.map { $0 != trimmed } ?? false,
                answeredAt: now,
                interaction: interaction ?? (suggestionIndex == nil ? "freeform" : "suggestion")
            )
            value.questionStatus = .answered
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
            value.questionStatus = .skipped
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
