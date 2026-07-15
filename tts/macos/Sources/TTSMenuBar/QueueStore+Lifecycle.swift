import Darwin
import Foundation

extension QueueStore {
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

    func requiredPendingQuestion(id: String) throws -> TTSItem {
        guard let value = try itemUnlocked(id: id) else { throw QueueOperationError.itemNotFound(id) }
        guard value.isPendingQuestion else { throw QueueOperationError.questionAlreadyResolved(id) }
        return value
    }

    static func selectedSuggestionIDs(for draft: TTSQuestionDraft) -> [String] {
        if !draft.suggestionIDs.isEmpty { return draft.suggestionIDs }
        return draft.suggestionID.map { [$0] } ?? []
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func copyAnswerAttachments(
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

    static func isReadableRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let string = String(result).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return string.isEmpty ? "item" : string
    }

    static func availableDestination(named filename: String, in directory: URL) -> URL {
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

    func saveOperation(_ operation: QueueOperation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = operationsDirectory.appendingPathComponent("\(operation.createdAt)-\(operation.id).json")
        try encoder.encode(operation).write(to: url, options: .atomic)
    }

    func withOperationsLock<T>(_ body: () throws -> T) throws -> T {
        try withFileLock(LOCK_EX, body)
    }

    func withOperationsReadLock<T>(_ body: () throws -> T) throws -> T {
        try withFileLock(LOCK_SH, body)
    }

    func withFileLock<T>(_ operation: Int32, _ body: () throws -> T) throws -> T {
        try prepare()
        let descriptor = open(operationsLockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open operations lock") }
        defer { close(descriptor) }
        guard flock(descriptor, operation) == 0 else { throw posixError("lock operations") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func reaches(
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

    func posixError(_ operation: String, code: Int32 = errno) -> NSError {
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
