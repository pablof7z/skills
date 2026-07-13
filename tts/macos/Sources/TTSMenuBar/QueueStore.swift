import Darwin
import Foundation

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

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadItems() throws -> [TTSItem] {
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
        try prepare()
        let destination = itemsDirectory.appendingPathComponent("\(item.id).json")
        var value = item
        if let data = try? Data(contentsOf: destination),
           let existing = try? JSONDecoder().decode(TTSItem.self, from: data) {
            value.attachments = Self.mergingPreparedAttachments(
                value.attachments,
                with: existing.attachments
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: destination, options: .atomic)
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
